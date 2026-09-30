//
//  NativeAgentLoop.swift
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

//  逐行为移植 subagent/sidecar/agent_engine/loop.py 的 run_tool_loop 内核
//  （⛔ 只读行为规格源，2125 行；语义分歧以 Python 源码为准）：
//    · 轮次循环：cancel/inject 检查点（不打断当前轮、下轮开始读入、取出即清空）
//      → 懒加载升档（0.4.31 D3，置于 90% 预警之前并回填 context_limit）
//      → M2 溢出预警（compact_required / compact_auto，发事件即返回）
//      → chat_stream 消费（token/thinking/tool_calls/done/stream_error）
//      → 最后一轮插入补救（0.4.23：done 前补 drain，continue 让模型真读到）
//      → 工具执行（web_search 去重拦截 / read_skill / search_knowledge /
//        archive_work_unit / app_control / Computer Use / delegate_task 路由，
//        其余走 NativeToolRegistry）→ tool_result → TS-105 熔断感知停止
//      → 结果回注（role=user 内嵌结构化 JSON tool_report，qwen 兼容格式）
//      → 轮末 state 前重算 ctx_chars（0.4.22 checkpoint-109）
//    · 熔断双保险：轮次上限（默认 200，config 覆盖 1-1000）+ 连续 2 轮工具全败
//    · REQ-PERF-002 重复动作熔断（0.7.4 W3）：同一工具+相同参数连续失败/
//      显式零进展达阈值（config key agent.repeatActionFuse，缺省 3，0=关闭）
//      → 报错停轮；web_search 去重拦截分支不计入（自带拦截语义）
//    · full_text 跨轮累积（#3/0.4.19：done 带完整文本，不是最后一轮残片）
//    · 报错载荷（0.4.9 任务161）：detail（原因+失败明细）+ analysis（报错分析
//      模型人话诊断；未配置/超时/异常静默降级，绝不丢原始错误）
//    · _measure_ctx_chars 上下文计量（msgs 全部字符串字段 + tools 声明 JSON 长度）
//
//  本波工具路由边界（W4a 纪律：只建内核、不翻路由）：
//    · 已接：search_knowledge（NativeKnowledgeStore 适配）、文件/Office 工具
//      （NativeRegistryToolExecutor，含 web_search/install_*/create_document）
//    · 占位：delegate_task（W4b 注入 NativeDelegationRunner）、
//      app_control / computer_use（W4c 注入）、read_skill（skills_mgr 仍 HTTP）、
//      archive_work_unit（归档执行器待装配）——未注入时按 Python 原文案
//      或「尚未原生接管」如实报错，绝不静默吞。
//
//  偏差（汇报清单同步）：
//    ① 连接器异常（OllamaAPIError/网络错误族）在 Python 中穿透 run_tool_loop 由
//       app.py gen() 兜底转 error 事件；Swift loop 自包含，在 chatStream 消费处
//       do/catch 转 error 事件（等价 app.py 最终安全网，禁止裸抛堆栈）。
//    ② 懒加载档位表默认实例为【每次运行新建】（Python 为进程级只升不降表）——
//       生产装配（W4c 内核接线）应注入进程级共享 NativeLazyCtxTiers；测试注入
//       独立实例保证隔离。对行为的影响仅限 num_ctx 档位记忆，预警阈值语义不变。
//    ③ Python dict 保插入序，JSONValue 无序：失败明细的参数摘要按键名字典序
//       （内容等价，顺序不同）；tool_report 回注 JSON 键序同理（dumpsUTF8 字典序）。
//    ④ Python len() 计码点：break_at / ctx_chars / 摘要截断统一用 unicodeScalars.count。
//    ⑤ 心跳竞争（app.py gen() 15s 定时器）与 SSE 行序列化属 W4c 路由层，不在内核。
//

import Foundation

// ════════════════════════════════════════════════════════════
// MARK: - 事件（Python yield 的 {"event": ..., "data": ...} 同构）
// ════════════════════════════════════════════════════════════

/// run_tool_loop 产出的一条事件。event/data 键与 Python yield dict 逐字段对齐：
///   token          {"delta"}
///   thinking       {"delta"}
///   tool_call      {"id","name","args","status":"running"}
///   tool_result    {"id","name","ok","summary","error"(恒在,成功为null),"created_agent"?}
///   state          {"step","max","tokens_used","prompt_eval_count","ctx_chars"}
///   done           {"content"(全文),"tool_calls":[{"id","name","ok","summary","error"?,"args"?}]}
///   error          {"detail","analysis"?,"analysis_model"?}
///   cancelled      {"detail":"已停止"}
///   segment_break  {"injected_messages":[{"role":"user","content"}],"break_at"}
///   compact_required / compact_auto  {"used","limit","est_rounds_left"}
public struct NativeAgentLoopEvent: Sendable, Equatable {
    public let event: String
    public let data: [String: JSONValue]
    public init(event: String, data: [String: JSONValue]) {
        self.event = event
        self.data = data
    }
}

// ════════════════════════════════════════════════════════════
// MARK: - 工具执行接缝（等价 Python 侧 execute_tool 单点入口；
//        测试可注入假执行器，对齐 test_loop 对 _registry._web_search 的 patch 语义）
// ════════════════════════════════════════════════════════════

public protocol NativeLoopToolExecutor: Sendable {
    /// 返回 {"ok": bool, ...} 结果字典（NativeToolRegistry.execute 同构）。
    func executeLoopTool(_ name: String, args: [String: JSONValue],
                         sandboxRoot: String) async -> [String: JSONValue]
}

/// 生产默认：走 W3a 原生注册表（8 工具 + create_document/doc_reader）。
public struct NativeRegistryLoopToolExecutor: NativeLoopToolExecutor {
    public let context: NativeToolContext
    public let authorizer: (any NativeToolAuthorizer)?
    public init(context: NativeToolContext, authorizer: (any NativeToolAuthorizer)? = nil) {
        self.context = context
        self.authorizer = authorizer
    }
    public func executeLoopTool(_ name: String, args: [String: JSONValue],
                                sandboxRoot: String) async -> [String: JSONValue] {
        await NativeToolRegistry.execute(name, args: args, sandboxRoot: sandboxRoot,
                                         authorizer: authorizer, context: context)
    }
}

// ════════════════════════════════════════════════════════════
// MARK: - 懒加载档位表（infer_options.py 0.4.31 D1~D3 移植）
// ════════════════════════════════════════════════════════════

/// num_ctx 档位表（Python 模块级 _CTX_LAZY_STATE 等价物）：每模型一槽、只升不降、
/// 不持久化。生产应注入进程级共享实例（见文件头偏差②）。
public final class NativeLazyCtxTiers: @unchecked Sendable {

    public static let startDefault = 12288                 // CTX_LAZY_START_DEFAULT
    public static let startRange = 2048...1_048_576        // CTX_LAZY_START_RANGE
    public static let bumpThreshold = 0.85                 // CTX_LAZY_BUMP_THRESHOLD

    private let lock = NSLock()
    private var state: [String: Int] = [:]                 // model → 当前档（只升不降）
    private let configProvider: @Sendable () -> [String: JSONValue]

    public init(configProvider: @escaping @Sendable () -> [String: JSONValue]) {
        self.configProvider = configProvider
    }

    private func config() -> [String: JSONValue] { configProvider() }

    /// lazy_enabled()：默认 true；非法值按默认开处理。
    public func lazyEnabled() -> Bool {
        guard let v = config()["ctx_lazy_enabled"], v != .null else { return true }
        return v.bool ?? true
    }

    /// lazy_start()：默认 12288；非法/越界夹到合法范围。
    public func lazyStart() -> Int {
        guard let raw = config()["ctx_lazy_start"], let f = PySem.toFloat(raw) else {
            return Self.startDefault
        }
        return min(max(Int(f), Self.startRange.lowerBound), Self.startRange.upperBound)
    }

    /// configured_num_ctx(model)：该模型配置的 num_ctx（三级键匹配；未配置 → nil）。
    public func configuredNumCtx(_ model: String) -> Int? {
        let raw = NativeWorkflowHTTPConnector.rawModelOptions(model: model, config: config())
        guard let v = raw["num_ctx"] else { return nil }
        if case .int(let i) = v, i > 0 { return Int(i) }
        guard let f = PySem.toFloat(v), f > 0 else { return nil }
        return Int(f)
    }

    /// lazy_ceiling(model, backend=None)：懒加载上限 = 用户配置的 num_ctx；
    /// nil = 不生效（走旧逻辑）。backend 显式传入优先于 config（Python L255
    /// `(backend or config).strip().lower()` 同款；P3-W3a MP 连接器显式传
    /// "model_package"——模型包路由下 config 后端可能是 ollama/openai）。
    public func lazyCeiling(_ model: String, backend: String? = nil) -> Int? {
        guard lazyEnabled() else { return nil }
        let raw = (backend?.isEmpty == false ? backend!
            : (config()["inference_backend"]?.string ?? "ollama"))
        let be = raw.trimmingCharacters(in: .whitespaces).lowercased()
        guard be == "ollama" || be == "model_package" else { return nil }
        return configuredNumCtx(model)
    }

    /// _tier_locked：取当前档（须持锁）。首次初始化起始档；配置调低时钳到上限（不写回）。
    private func tierLocked(_ model: String, ceiling: Int) -> Int {
        if let cur = state[model] { return min(cur, ceiling) }
        let cur = min(lazyStart(), ceiling)   // ceiling < 起始档 → 直接全量（D2）
        state[model] = cur
        return cur
    }

    /// current_ctx_for(model, backend=None)：当前应使用的 num_ctx 档；懒加载不生效 → nil。
    public func currentCtxFor(_ model: String, backend: String? = nil) -> Int? {
        guard let ceiling = lazyCeiling(model, backend: backend) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return tierLocked(model, ceiling: ceiling)
    }

    /// maybe_bump_ctx(model, est_tokens, backend=None)：est ≥ 当前档×0.85 且档 < 上限 → 升一档。
    public func maybeBumpCtx(_ model: String, estTokens: Double, backend: String? = nil) -> Bool {
        guard let ceiling = lazyCeiling(model, backend: backend) else { return false }
        lock.lock()
        defer { lock.unlock() }
        let cur = tierLocked(model, ceiling: ceiling)
        if cur >= ceiling { return false }
        if estTokens < Double(cur) * Self.bumpThreshold { return false }
        let nxt = min(cur * 2, ceiling)
        if nxt <= cur { return false }
        state[model] = nxt
        return true
    }

    /// _reset_ctx_lazy_state：测试专用（生产不得调用——只升不降是并发语义的一部分）。
    public func reset() {
        lock.lock()
        state = [:]
        lock.unlock()
    }
}

// ════════════════════════════════════════════════════════════
// MARK: - 内核本体
// ════════════════════════════════════════════════════════════

public enum NativeAgentLoop {

    // ── 协议常量（loop.py L50-64）──
    public static let maxRoundsDefault = 200        // MAX_ROUNDS_DEFAULT（config max_tool_rounds 覆盖，1-1000）
    public static let consecutiveFailLimit = 2      // CONSECUTIVE_FAIL_LIMIT
    public static let computerUseMaxStrikes = 2     // COMPUTER_USE_MAX_STRIKES（截屏不计入）
    public static let searchCircuitStop = 1         // SEARCH_CIRCUIT_STOP（TS-105）
    public static let summaryMaxChars = 200         // SUMMARY_MAX_CHARS
    public static let archiveMinMessages = 4        // ARCHIVE_MIN_MESSAGES
    public static let errorAnalysisTimeout = 60.0   // _ERROR_ANALYSIS_TIMEOUT

    // MARK: 小工具

    /// Python len(str)：码点计数（unicodeScalars）。
    static func pyLen(_ s: String) -> Int { s.unicodeScalars.count }

    static func pyPrefix(_ s: String, _ n: Int) -> String { String(s.unicodeScalars.prefix(n)) }

    /// json.dumps(x, ensure_ascii=False)（默认分隔符 ', ' / ': '）。
    static func dumps(_ v: JSONValue) -> String { NativeDatabase.dumpsUTF8(v) }

    static func err(_ message: String) -> [String: JSONValue] {
        ["ok": .bool(false), "error": .string(message)]
    }

    static func pyTrim(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// _normalize_query：去首尾空白、压缩连续空白、转小写（搜索去重判定）。
    public static func normalizeQuery(_ q: String) -> String {
        q.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    // MARK: _measure_ctx_chars（B3 0.4.8；轮初/轮末两处共用，口径不漂移）

    /// msgs 全部角色、全部字符串字段之和 + tools 声明的 JSON 长度。
    /// 前端指示器据此 ×0.6 显示 token（含 system prompt 与工具声明基线）。
    public static func measureCtxChars(_ msgs: [[String: JSONValue]],
                                       _ toolsSpecList: [JSONValue]) -> Int {
        var total = 0
        for m in msgs {
            for (_, v) in m {
                if case .string(let s) = v { total += pyLen(s) }
            }
        }
        if !toolsSpecList.isEmpty {
            total += pyLen(dumps(.array(toolsSpecList)))
        }
        return total
    }

    // MARK: _summarize（tool_result 摘要：截断 200 字，非完整 content）

    public static func summarize(_ result: [String: JSONValue]) -> String {
        var body: String
        if result["ok"] == .bool(true) {
            let kind = result["_kind"]?.string
            if kind == "read_skill" {
                // TS-110 M4：技能读取 → 摘要显示描述
                body = "已加载技能「\(result["name"]?.string ?? "")」：\(result["description"]?.string ?? "")"
            } else if kind == "image" {
                // checkpoint-067 R-4：图片 → 已转为图像输入
                body = "已读取图片 \(result["size"]?.int ?? 0) 字节，已转为图像输入"
            } else if result["content"] != nil {
                let truncated = (result["truncated"]?.bool ?? false)
                    || result["truncated"] == .int(1)
                body = "已读取 \(result["size"]?.int ?? 0) 字节" + (truncated ? "（已截断）" : "")
            } else if case .array(let entries)? = result["entries"] {
                body = "\(entries.count) 个条目"
            } else if result["summary"] != nil {
                // TS-107 M3-1：委派结果展示子任务摘要与状态
                body = "[\(result["status"]?.string ?? "done")] \(result["summary"]?.string ?? "")"
            } else {
                // str(result.get("path") or result.get("bytes") or "ok")：Python or 真值语义
                if let p = result["path"]?.string, !p.isEmpty {
                    body = p
                } else if let b = result["bytes"]?.int, b != 0 {
                    body = String(b)
                } else {
                    body = "ok"
                }
            }
        } else {
            body = result["error"]?.string ?? "unknown"
        }
        return pyLen(body) <= summaryMaxChars ? body : pyPrefix(body, summaryMaxChars) + "…"
    }

    // MARK: _collect_failure_detail（0.4.9 任务161：失败明细，按时间倒序取最近 N 条）

    static func collectFailureDetail(_ log: [[String: JSONValue]], maxItems: Int = 6) -> String {
        let fails = log.filter { $0["ok"] != .bool(true) }
        if fails.isEmpty { return "" }
        var out: [String] = []
        for e in fails.suffix(maxItems) {
            let args = e["args"]?.object ?? [:]
            // 参数摘要：只取关键标识字段（避免超长）。Python 保插入序；此处字典序（偏差③）。
            var brief = args.keys.sorted().prefix(4)
                .map { "\($0)=\(pyPrefix(WFText.pyStr(args[$0]!), 60))" }
                .joined(separator: ", ")
            if brief.isEmpty { brief = "（无参数）" }
            let errText = pyPrefix(e["error"]?.string ?? "未知错误", 300)
            out.append("  · \(e["name"]?.string ?? "?")(\(brief)) → \(errText)")
        }
        var s = out.joined(separator: "\n")
        if fails.count > maxItems {
            s += "（共 \(fails.count) 次失败，列出最近 \(min(fails.count, maxItems)) 次）"
        }
        return s
    }

    // MARK: 报错分析模型（_resolve_error_analysis_model + _analyze_error）

    static func resolveErrorAnalysisModel(config: () -> [String: JSONValue]) -> String {
        let c = config()
        if let m = c["error_analysis_model"]?.string,
           !pyTrim(m).isEmpty { return pyTrim(m) }
        if let m = c["default_model"]?.string { return pyTrim(m) }
        return ""
    }

    /// _analyze_error：报错分析模型把技术错误翻译成人话诊断。
    /// 未配置/异常/超时 → 空串（静默降级；绝不因分析失败影响原始错误呈现）。
    static func analyzeError(reason: String, failureDetail: String,
                             connector: (any NativeChatConnector)?,
                             config: @escaping () -> [String: JSONValue]) async -> String {
        let model = resolveErrorAnalysisModel(config: config)
        if model.isEmpty || connector == nil { return "" }
        if reason.isEmpty && failureDetail.isEmpty { return "" }
        let prompt = "你是错误诊断助手。下面是本地 AI 应用运行时的一次失败，请用【不超过 3 句话】的简体中文，"
            + "先说最可能的根本原因，再给用户一条最该做的下一步动作。"
            + "不要复述错误原文，不要编造不存在的信息，不确定就说不确定。\n\n"
            + "【失败原因】\n\(reason)\n\n【失败明细】\n\(failureDetail.isEmpty ? "（无工具调用记录）" : failureDetail)"
        do {
            let text = try await withTimeout(errorAnalysisTimeout) {
                try await connector!.chat(model: model, messages: [[
                    "role": .string("user"), "content": .string(prompt),
                ]])
            }
            return pyPrefix(pyTrim(text), 600)
        } catch {
            return ""
        }
    }

    /// asyncio.wait_for(timeout) 等价：竞速 op 与睡眠；超时抛错（调用方吞）。
    static func withTimeout<T: Sendable>(_ seconds: Double,
                                         _ op: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await op() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw NativeChatConnectorError.network("error_analysis_timeout")
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    /// _build_error_payload：detail（原因+失败明细）+ analysis（人话诊断，可选）。
    static func buildErrorPayload(_ reason: String, _ log: [[String: JSONValue]],
                                  connector: (any NativeChatConnector)?,
                                  config: @escaping () -> [String: JSONValue]) async -> [String: JSONValue] {
        let detailPart = collectFailureDetail(log)
        let detail = reason + (detailPart.isEmpty ? "" : "\n\n【失败明细】\n\(detailPart)")
        let analysis = await analyzeError(reason: reason, failureDetail: detailPart,
                                          connector: connector, config: config)
        var payload: [String: JSONValue] = ["detail": .string(detail)]
        if !analysis.isEmpty {
            payload["analysis"] = .string(analysis)
            payload["analysis_model"] = .string(resolveErrorAnalysisModel(config: config))
        }
        return payload
    }
}


// ════════════════════════════════════════════════════════════
// MARK: - tools_spec（loop.py L183-639 逐字段移植；Ollama OpenAI 风格 tools 参数）
// ════════════════════════════════════════════════════════════

extension NativeAgentLoop {

    private static func fnTool(_ name: String, _ description: String,
                               properties: [String: JSONValue],
                               required: [String] = []) -> JSONValue {
        var params: [String: JSONValue] = [
            "type": .string("object"),
            "properties": .object(properties),
        ]
        if !required.isEmpty {
            params["required"] = .array(required.map { .string($0) })
        }
        return .object([
            "type": .string("function"),
            "function": .object([
                "name": .string(name),
                "description": .string(description),
                "parameters": .object(params),
            ]),
        ])
    }

    private static func prop(_ type: String, _ description: String,
                             extra: [String: JSONValue] = [:]) -> JSONValue {
        var o: [String: JSONValue] = ["type": .string(type)]
        if !description.isEmpty { o["description"] = .string(description) }
        for (k, v) in extra { o[k] = v }
        return .object(o)
    }

    /// 工具规格列表。withDelegation=false 剔除 delegate_task（子会话防递归委派）；
    /// withInstall=false 剔除 install_plugin/install_skill（0.4.9 F2：子 Agent 无联网安装权）。
    public static func toolsSpec(withDelegation: Bool = true, withKnowledge: Bool = false,
                                 withInstall: Bool = true, withArchive: Bool = false,
                                 withAppControl: Bool = false,
                                 withComputerUse: Bool = false) -> [JSONValue] {
        var spec: [JSONValue] = [
            fnTool("list_dir", "列出目录下的文件与目录。", properties: [
                "path": prop("string", "目录路径（相对工作目录或绝对路径），缺省为工作目录本身"),
            ]),
            fnTool("read_file",
                   "读取文件的文本内容（超过 1MB 会截断并标记）。"
                   + "读取图片文件（.png/.jpg/.jpeg/.gif/.webp/.bmp/.heic 等）时，"
                   + "图片会自动转换为图像输入注入你的视觉上下文，你可以直接描述/识别图片内容（无需 OCR 工具）。",
                   properties: [
                       "path": prop("string", "文件路径（相对工作目录或绝对路径）"),
                   ], required: ["path"]),
            fnTool("write_file", "把文本内容写入文件（自动创建父目录，覆盖已有文件）。", properties: [
                "path": prop("string", "文件路径（相对工作目录或绝对路径）"),
                "content": prop("string", "要写入的文本内容"),
            ], required: ["path", "content"]),
            fnTool("create_dir", "创建目录（自动创建父目录）。", properties: [
                "path": prop("string", "目录路径（相对工作目录或绝对路径）"),
            ], required: ["path"]),
            // 0.4.6：Office 文档生成（内置）
            fnTool("create_document",
                   "生成 Word/Excel/PowerPoint/Markdown（docx/xlsx/pptx/md）文档。"
                   + "用户要求报告、表格、幻灯片等正式文档时用本工具（而非 write_file 纯文本）。"
                   + "docx 默认 A4 竖版、宋体、页脚自动页码「第X页 共Y页」。"
                   + "content 必须是结构化 JSON："
                   + "docx/md 用 {title, blocks:[{type:'heading',level,text}|{type:'paragraph',text}|{type:'bullets',items:[..]}|{type:'table',rows:[[..],..]}|{type:'page_break'}|{type:'image',layout:'single'|'grid',paths:[..],width_cm,height_cm,caption}]}；"
                   + "image 块：layout='single' 单图/多张原文居中，layout='grid' 一行3列网格；"
                   + "width_cm / height_cm 单位厘米：⛔ **只传其中一个**，另一维按原图比例自动推算（推荐）；"
                   + "两者都传会强制拉伸变形，仅在确需精确尺寸时用；都不传默认 width_cm=13（A4 正文宽）；"
                   + "page_break 分页（每份证据独立起页时用）；"
                   + "xlsx 用 {sheets:[{name, rows:[[单元格,..],..]}]}；"
                   + "pptx 用 {slides:[{title, bullets:[..], notes}]}.",
                   properties: [
                       "path": prop("string", "保存路径含扩展名（如 报告.docx / 数据.xlsx / 幻灯片.pptx / 总结.md）"),
                       "doc_type": prop("string", "文档类型 docx/xlsx/pptx/md（默认从扩展名推断，可省略）"),
                       "content": prop("object", "结构化内容（按上方契约填写，对象而非字符串）"),
                   ], required: ["path", "content"]),
            fnTool("delete_path",
                   "删除文件或目录（目录会递归删除）。涉及系统敏感位置时会请求用户确认。",
                   properties: [
                       "path": prop("string", "要删除的文件或目录路径（相对工作目录或绝对路径）"),
                   ], required: ["path"]),
            // TS-104 R01：联网搜索
            fnTool("web_search",
                   "联网搜索实时信息（天气、新闻、价格、事实查询等）。"
                   + "网络开关关闭且域名未放行时会返回拒绝，此时应如实告知用户。",
                   properties: [
                       "query": prop("string", "搜索关键词"),
                       "max_results": prop("integer", "返回条数（默认5，上限10）"),
                   ], required: ["query"]),
            // TS-110 M4：按需读取技能指令
            fnTool("read_skill",
                   "读取指定技能（Skill）的完整指令内容。仅当【可用技能】清单中的某个技能"
                   + "与当前任务相关、且你需要其详细执行指令时调用。",
                   properties: [
                       "name": prop("string", "技能名（见【可用技能】清单）"),
                   ], required: ["name"]),
            // checkpoint-066：对话内安装插件
            fnTool("install_plugin",
                   "安装一个插件（Plugin）到应用中。用户要求安装插件时使用。"
                   + "插件仓库需含 manifest.json；安装成功后可在 设置→插件管理 中查看与管理。",
                   properties: [
                       "source": prop("string",
                                      "GitHub 仓库 URL（如 https://github.com/owner/repo）"
                                      + "或本地插件目录的绝对路径"),
                   ], required: ["source"]),
            // checkpoint-066：对话内安装技能
            fnTool("install_skill",
                   "安装一个技能（Skill）到应用中。用户要求安装技能时使用。"
                   + "技能目录需含 SKILL.md；安装成功后可在 设置→技能 中查看与管理。",
                   properties: [
                       "source": prop("string", "git 仓库 URL 或含 SKILL.md 的本地目录绝对路径"),
                   ], required: ["source"]),
        ]
        if withDelegation {
            // TS-107 M3-1：主-子委派（子会话 with_delegation=False 拿不到此工具）
            spec.append(fnTool("delegate_task",
                "把子任务委派给项目内另一个 Agent 独立完成，仅在需要分工时使用。"
                + "子 Agent 看不到当前对话历史，任务书必须自包含。"
                + "消息附图自动随委派传给子 Agent（任务书写“识别附图”即可）；"
                + "文件夹中的图片用 image_paths 传入。",
                properties: [
                    "target": prop("string", "目标 Agent 的名称或 ID"),
                    "task": prop("string", "任务书：目标、背景、输入材料，必须自包含"),
                    "expect": prop("string", "交卷标准：期望子 Agent 产出什么"),
                    "suggested_role": prop("string",
                        "目标 Agent 不存在时，按此角色自动新建子 Agent 并执行"
                        + "（如'数据分析师'）。可不填，不填时直接用 target 名称新建。"),
                    "image_paths": prop("array",
                        "要随委派传给子 Agent 的图片文件路径列表（相对沙盒根或绝对路径，如 'images/a.png'）。"
                        + "适用场景：批量图片识别/转写等。不填时仅传聊天附着图。",
                        extra: ["items": .object(["type": .string("string")])]),
                    // #15（0.4.19）：文档路径通道——传【路径】由子 Agent 自己读
                    "file_paths": prop("array",
                        "要交给子 Agent 阅读的【文档/文本文件】路径列表"
                        + "（相对沙盒根或绝对路径，如 '证据/律师函.docx'）。"
                        + "⛔ 子 Agent 会自己 read_file 读取这些文件"
                        + "（docx/xlsx/pptx/pdf 均能解析为文本+格式），"
                        + "所以【你绝不要自己先读文件再把内容抄进任务书】"
                        + "——那样会把整篇文档塞进你的上下文、极慢且容易截断。"
                        + "你只需在任务书里说明要对这些文件做什么。"
                        + "图片请用 image_paths（直接注入视觉流），不要用本参数。",
                        extra: ["items": .object(["type": .string("string")])]),
                    "simple_mode": prop("boolean",
                        "简单委派模式：子 Agent 直接输出结果本身，不要求 JSON 交卷、不追问重交。"
                        + "带图委派会自动启用，无需填写；仅当无图但任务属于纯产出型"
                        + "（如逐字转写、摘录，目标为不擅长 JSON 的小模型）时可显式传 true。"),
                    "model": prop("string",
                        "3.47.2 委派模型自选：指定子任务用哪个本地模型运行"
                        + "（如图片识别选视觉/OCR 专用小模型，长文推理选大模型）。"
                        + "参考系统提示词【可用模型及特长】段落按特长选择；未列出或不填时，"
                        + "自动新建的子 Agent 用你的当前模型，复用已有子 Agent 时则沿用其自身模型。"
                        + "填了不存在的模型名会被拒绝并列出可用模型。"),
                ], required: ["target", "task", "expect"]))
        }
        if withKnowledge {
            // TS-120 阶段二：知识仓库主动检索（拉模式；结果本轮用完即弃）
            spec.append(fnTool("search_knowledge",
                "检索本地知识仓库（拉模式）。仅当用户明确要求检索知识库，"
                + "或任务必须引用此前沉淀的知识/对话时才调用。"
                + "结果仅本轮可见，不写入对话上下文。",
                properties: [
                    "query": prop("string", "检索词或自然语言描述（支持换述）"),
                    "scope": prop("string", "检索范围：project=仅本项目 / global=仅全局 / 留空=两者",
                                  extra: ["enum": .array([.string("project"), .string("global"), .string("all")])]),
                    "mode": prop("string", "检索模式：hybrid=关键词+语义融合(默认) / keyword=仅关键词 / semantic=仅语义",
                                 extra: ["enum": .array([.string("hybrid"), .string("keyword"), .string("semantic")])]),
                    "limit": prop("integer", "返回条数上限，默认 5", extra: ["default": .int(5)]),
                ], required: ["query"]))
        }
        if withArchive {
            // 0.4.9（3.47.1 单元归档）：仅当会话窗开关开启时才暴露（关闭时零开销）
            spec.append(fnTool("archive_work_unit",
                "把【已完成的一个工作单元】的对话移入知识仓库，脱离后续上下文"
                + "（用于批量任务：每完成一个单元就归档一次，防止上下文无限膨胀）。"
                + "调用前提（必须全部满足）：①该单元的任务确实已完成；"
                + "②该单元的产出文件已真实落盘（先用 list_dir 确认）。"
                + "系统会自动打包【上次归档点之后】的消息，并保留会话第一条用户消息"
                + "（任务总指令）永不归档，因此你始终能看到总任务与剩余清单。"
                + "距上次归档不足 4 条消息时会被拒绝（防滥用）。"
                + "归档后内容仍可用 search_knowledge 搜回。",
                properties: [
                    "title": prop("string",
                        "该工作单元的名称（如'《赵兴柱诉刘禄九》案情分析'），"
                        + "会作为知识条目标题，便于日后检索"),
                    "summary": prop("string", "一句话说明本单元完成了什么、产出在哪个文件"),
                ], required: ["title", "summary"]))
        }
        if withAppControl {
            // 0.4.9（3.48.2 应用内模块控制）：仅当开关开启时暴露
            spec.append(fnTool("app_control",
                "调用应用内模块完成结构化任务（工作流 / 知识仓库 / 圆桌）。"
                + "适用场景：需要跑一个确定性流程（如批量识图用工作流，比逐个委派更快更稳）、"
                + "查历史沉淀的知识、发起多 Agent 圆桌会诊。"
                + "调用前先看系统提示词【可用应用模块动作】清单确认模块与动作名。"
                + "低成本动作（查询/检索）直接执行；高成本动作（运行工作流、创建圆桌）"
                + "会先弹窗请用户确认。",
                properties: [
                    "module": prop("string", "模块名，见【可用应用模块动作】清单（如 workflow / knowledge / roundtable）"),
                    "action": prop("string", "动作名（如 list / run / get_runs / search / inject / groups / create）"),
                    "params": prop("object", "该动作的参数对象，字段见清单中各动作说明"),
                ], required: ["module", "action"]))
        }
        if withComputerUse {
            // 0.4.9（3.48.1 CU 一期 MVP）：仅当总开关开启时暴露。
            // ⚠️ 直接操作用户真实电脑，路由层强制：白名单校验 + 每步确认。
            spec.append(fnTool("screen_view",
                "截取当前屏幕，图片会进入你的视觉上下文，你可以直接看到屏幕内容。"
                + "每次要点击或输入之前，都应先截屏看清当前界面（界面会变，别凭记忆操作）。"
                + "返回结果含 coord_factor：你从图上看到的坐标是【图片像素坐标】，"
                + "调用 mouse_click 时必须先乘以 coord_factor 换算成屏幕坐标，否则会点偏。",
                properties: [:]))
            spec.append(fnTool("mouse_click",
                "在屏幕坐标点击。坐标必须是【逻辑点】——即用 screen_view 看到的像素坐标"
                + "乘以 coord_factor 换算后的值。执行前会请用户确认。",
                properties: [
                    "x": prop("number", "横坐标（逻辑点，已乘 coord_factor）"),
                    "y": prop("number", "纵坐标（逻辑点，已乘 coord_factor）"),
                    "button": prop("string", "鼠标键，默认 left",
                                   extra: ["enum": .array([.string("left"), .string("right")])]),
                    "clicks": prop("integer", "1=单击（默认），2=双击",
                                   extra: ["enum": .array([.int(1), .int(2)])]),
                ], required: ["x", "y"]))
            spec.append(fnTool("keyboard_type",
                "在当前焦点处输入文本（支持中文与符号，单次上限 2000 字符）。"
                + "执行前会请用户确认。输入前请确保目标输入框已获得焦点（先点击它）。",
                properties: [
                    "text": prop("string", "要输入的文本"),
                ], required: ["text"]))
            spec.append(fnTool("keyboard_hotkey",
                "按下按键或组合键，如 'return'、'cmd+c'、'cmd+shift+4'、'esc'。"
                + "执行前会请用户确认。",
                properties: [
                    "keys": prop("string", "按键名，组合键用 + 连接（如 cmd+c）"),
                ], required: ["keys"]))
            // 0.4.32（CU 二期 E3）：只读元素语义查询
            spec.append(fnTool("element_locate",
                "只读查询屏幕坐标（逻辑点，同 mouse_click）处的界面元素语义："
                + "角色、标题与精确 frame，用于点击前校准坐标。",
                properties: [
                    "x": prop("number", "横坐标（逻辑点）"),
                    "y": prop("number", "纵坐标（逻辑点）"),
                ], required: ["x", "y"]))
            // 0.4.33（CU 三期 R1）：任务宏（录制/回放/列表）
            spec.append(fnTool("cu_macro_record",
                "任务宏录制开关。action=start 开始录制（需带 name）：此后你经 "
                + "mouse_click / keyboard_type / keyboard_hotkey 执行成功的动作会"
                + "逐步录入宏；action=stop 停止并保存，返回宏 id 与步数。"
                + "录制窗口内没有任何动作时【不会保存】（返回 saved=false 与说明）。"
                + "⛔ 录制的只是你自己发起的 CU 动作序列，用户手动操作不会被捕获。",
                properties: [
                    "action": prop("string", "start=开始录制，stop=停止并保存",
                                   extra: ["enum": .array([.string("start"), .string("stop")])]),
                    "name": prop("string", "宏名称（action=start 时必填）"),
                ], required: ["action"]))
            spec.append(fnTool("cu_macro_replay",
                "回放已保存的任务宏（id 或 name 二选一；同名多个时必须用 id）。"
                + "回放是【语义重放】：点击步骤按元素 role/title 重定位（窗口挪位"
                + "仍命中），匹配不到时回落录制时的像素坐标；输入/按键按原内容重放。"
                + "回放驱动真实键鼠，开始前会请用户确认一次；目标应用未运行时"
                + "在该步报错并中止。0 步空宏不可回放（返回可读错误）。",
                properties: [
                    "id": prop("string", "宏 id（cu- 开头，见 cu_macro_list 返回）"),
                    "name": prop("string", "宏名称（与 id 二选一，id 优先）"),
                ]))
            spec.append(fnTool("cu_macro_list",
                "列出全部已保存的任务宏（id/名称/步数/创建时间）与当前录制状态。"
                + "回放前先调用本工具确认宏存在、拿到准确 id。"
                + "本工具组不提供删除：如需删除宏，请用户在宏管理界面操作。",
                properties: [:]))
        }
        // 0.4.9 F2：子 Agent（withInstall=false）剔除联网安装工具
        if !withInstall {
            spec = spec.filter { tool in
                guard case .object(let t) = tool, case .object(let fn) = t["function"],
                      let name = fn["name"]?.string else { return true }
                return name != "install_plugin" && name != "install_skill"
            }
        }
        return spec
    }
}


// ════════════════════════════════════════════════════════════
// MARK: - build_system_prompt（loop.py L643-799 逐字移植：红线区 → 身份 → 环境 → 工具说明）
// ════════════════════════════════════════════════════════════

extension NativeAgentLoop {

    /// 按需求顺序拼装：红线区 → 身份 → 环境 → 工具说明（+委派纪律）。零硬编码（全从入参）。
    /// M4（TS-110）：知识/记忆/技能注入（禁止事项并入红线区；优先级 记忆>知识）。
    public static func buildSystemPrompt(
        agentName: String,
        agentRole: String?,
        sandboxRoot: String,
        networkSwitch: String,
        currentTime: String? = nil,
        systemPrompt: String? = nil,
        canDelegate: Bool = false,
        knowledgeText: String = "",
        memoryText: String = "",
        prohibitions: [String]? = nil,
        skillsListText: String = "",
        modelStrengthsText: String = "",
        archiveEnabled: Bool = false,
        moduleCatalogText: String = "",
        computerUseEnabled: Bool = false
    ) -> String {
        let ts: String
        if let currentTime {
            ts = currentTime
        } else {
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyy-MM-dd HH:mm"
            ts = fmt.string(from: Date())
        }
        // 2026-08-28 融合方案：三态网络模式（auto/proxy，旧值 on→proxy / off→auto）
        let raw = networkSwitch.uppercased()
        let mode = ["ON", "PROXY", "1", "TRUE"].contains(raw) ? "proxy" : "auto"
        let net = mode == "proxy"
            ? "走代理模式：境内直连，境外经代理访问"
            : "自动探测模式：境内直连；境外访问失败时系统会自动切换策略并提示"
        let rolePart = agentRole.map { "角色：\($0)。" } ?? ""
        let spPart = systemPrompt.map { "\n补充设定：\($0)" } ?? ""
        // M4：用户禁止事项并入红线区（3.14：禁止事项 100% 拦截）
        var redline = "【禁止事项】不得执行未授权操作。"
        if let prohibitions, !prohibitions.isEmpty {
            redline += "\n用户设定的禁止事项（必须严格遵守，违反即错误）：\n"
                + prohibitions.prefix(20).map { "- \($0)" }.joined(separator: "\n")
        }
        var base = (
            "\(redline)\n"
            + "你是 \(agentName)，\(rolePart)\(spPart)\n"
            + "工作目录：\(sandboxRoot)。当前时间：\(ts)。网络模式：\(net)。\n"
            + "你可通过工具读写文件（list_dir/read_file/write_file/create_dir/delete_path）。"
            + "工作目录是默认的读写锚点，但你可以在用户需要时操作其他目录或修改配置文件，无需预先询问；"
            + "对系统敏感位置（系统目录、~/.ssh、应用数据目录等）的写入/删除，系统会向你请求确认；其余位置操作不受限。\n"
            + "需要实时信息（天气/新闻/价格等）时使用 web_search 工具（内置多源自动降级，会自行切换搜索源）。\n"
            + "【搜索纪律】每个问题最多搜索 1-2 次，且不得用相同/近似关键词重复搜索；"
            + "拿到搜索结果后立即整理回答，不要反复调用工具；"
            + "若工具返回含“已熔断”字样，表示境外源已被系统熔断，禁止再次调用 web_search，"
            + "直接向用户说明原因与恢复方法（启动代理 + 切走代理模式）；"
            + "搜索结果不理想时，换个不同角度的关键词再搜一次，仍不理想就直接基于已有信息回答并说明局限。\n"
            + "【重要】不要根据网络状态预判拒绝——用户询问实时信息时直接调用 web_search，以工具返回为准。"
            + "工具返回结构化 JSON，ok=false 时按 error 字段处理。\n"
            // 表#6（0.4.19）：附件拉模式的配套纪律（见路径必读，不得声称看不到文件）
            + "【文件路径纪律】用户消息正文、或工具返回结果里出现的**文件绝对路径**"
            + "（上传附件形如「（原件已保存：/…）」，也可能是导出产物、用户指定的任意路径），"
            + "只代表文件**在本机存在**，其**内容不会**自动出现在你的上下文里。\n"
            + "- 任务需要该文件内容时，⛔ **必须先用 read_file 读取该绝对路径**再作答，"
            + "不得声称「看不到文件」「没有收到内容」「无法读取」——那是没调用工具，不是能力缺失。\n"
            + "- read_file 支持 docx/xlsx/pptx/pdf/doc（自动解析为文本+表格+格式概要）与各类纯文本（含导出的 .md/.json）；"
            + "图片走视觉输入、无需 read_file。\n"
            + "- ⛔ 只有当消息与工具返回里**确实没有**任何路径时，才可如实说明未收到文件。\n"
            + "- 读取失败（文件不存在/格式不支持）时如实说明具体错误，不得编造文件内容。\n"
        )
        // M4：记忆（优先级高于知识）→ 知识库 → 技能清单
        if !memoryText.isEmpty {
            base += "\n【长期记忆】（用户沉淀的持久信息，请牢记并遵循）\n" + memoryText
        }
        if !knowledgeText.isEmpty {
            base += "\n【项目知识库】（本项目的参考资料；与【长期记忆】冲突时，以记忆为准）\n" + knowledgeText
        }
        if !skillsListText.isEmpty {
            base += "\n【可用技能】（以下技能可按需使用；需要某技能的详细指令时，"
                + "调用 read_skill 工具，参数 name 填技能名）\n" + skillsListText
        }
        // 0.4.9（3.48.2）：应用内模块动作清单——仅当设置开关开启时注入
        if !moduleCatalogText.isEmpty {
            base += "\n【可用应用模块动作】（用 app_control 工具调用：module=模块名, action=动作名, "
                + "params=参数对象。低成本查询类直接执行；运行工作流、创建圆桌等高成本动作"
                + "会先请用户确认，被拒绝时不要重试）\n" + moduleCatalogText
        }
        // 0.4.33（CU 三期 R1）：Computer Use 能力段——仅当总开关开启时注入
        if computerUseEnabled {
            base += (
                "\n【Computer Use】（已开启电脑操作能力）\n"
                + "- 截屏/点击/输入/元素定位可操作用户真实电脑：动作前先 screen_view 看清界面"
                + "（界面会变，别凭记忆操作），坐标按 coord_factor 换算；"
                + "点击/输入等副作用动作会请用户逐步确认。\n"
                + "- 【任务宏】用户说「录成宏 / 录制这个动作 / 回放宏」时，用 cu_macro_record"
                + "（action=start/stop）、cu_macro_replay、cu_macro_list，⛔ 不要自己写脚本模拟。\n"
                + "- 录制只捕获【你自己经 CU 工具发起的动作序列】（仅成功动作落步，"
                + "用户手动操作不会被捕获）；回放是语义重放（点击按元素 role/title 重定位，"
                + "匹配不到回落录制时像素坐标），驱动真实键鼠、开始前会请用户确认一次。"
            )
        }
        // 0.4.9（3.47.1）：单元归档纪律——仅当会话窗开关开启时注入
        if archiveEnabled {
            base += (
                "\n【单元归档纪律】（本会话已开启「单元归档」）\n"
                + "- 批量任务（如一次处理多个案件/多个文件夹）中，每【真正完成一个工作单元】、"
                + "且该单元的产出文件【已确认真实落盘】（先用 list_dir 核对）后，"
                + "调用 archive_work_unit(title=单元名, summary=一句话说明产出与文件位置)，"
                + "把这段对话移入知识仓库，防止上下文无限膨胀拖慢后续推理。\n"
                + "- 【禁止】单元未完成、产出未落盘、或只是中间步骤时就归档——"
                + "归档会脱离上下文，过早归档会丢失必要信息导致后续出错。\n"
                + "- 会话第一条用户消息（任务总指令）系统会自动保留、永不归档，"
                + "因此你始终能看到总任务与剩余清单；距上次归档不足 4 条消息时系统会拒绝归档。\n"
                + "- 归档后如需回看，用 search_knowledge 搜回（拉模式，不会自动注入）。\n"
                + "- 单个任务（非批量）无需归档，正常完成即可。"
            )
        }
        // 0.4.9（3.47.2）：模型特长画像——仅当用户配置了画像且可委派时注入
        if canDelegate && !modelStrengthsText.isEmpty {
            base += "\n【可用模型及特长】（委派子任务时可用 delegate_task 的 model 参数按特长选择；"
                + "未列出的模型也可用，但无特长说明）\n" + modelStrengthsText
        }
        if canDelegate {
            base += (
                "\n【委派纪律】\n"
                + "- 【强制】用户消息含\"让XX/请XX/派XX/叫XX/安排XX 做某事\"（XX 为任意名称或角色，"
                + "如'人事专员'）时，必须先调用 delegate_task 委派给 XX（不存在时系统会自动新建），"
                + "不得自己直接做该事、不得自己搜索后代答、更不得在未调用 delegate_task 的情况下"
                + "把回答描述成'已派XX查询'。\n"
                + "- 【串行约束】同一时间只委派一个子任务，等前一个交卷后再委派下一个"
                + "（本机性能受限，同时只跑 1 个大模型）。\n"
                + "- 需要分工时用 delegate_task 委派：任务书必须自包含，子 Agent 看不到本对话历史，"
                + "目标/输入/预期产出都要写进任务书。\n"
                + "- 【target 必填】委派必须写明 target（目标 Agent 名称）。调用失败提示缺参时，"
                + "按返回的可用 Agent 名单补填 target 后重新调用，不要凭空编造目标。\n"
                + "- 委派目标可以是项目内已有的 Agent；若目标不存在，系统会按建议角色"
                + "（不填则按目标名称）自动新建子 Agent 并执行，无需先询问用户。\n"
                + "- 子 Agent 交卷一般是固定 JSON（task_id/status/summary/artifacts）；"
                + "但带图委派（识别/转写）自动启用简单模式：子 Agent 直接返回内容本身，"
                + "没有 JSON 外壳，你直接采用其返回内容即可。你负责整合各交卷，"
                + "最终回复中标注每部分来自哪个子 Agent。\n"
                + "- 交卷标记异常（ok=false）时，如实告知用户哪个子任务缺失及原因，不要虚构其产出。\n"
                + "- 【强制】委派失败/交卷异常后，禁止你自己重新搜索或亲自完成该子任务来代答"
                + "（那会让委派失去意义，且你已看不到子 Agent 的中间过程）。正确做法：向用户说明"
                + "失败原因，建议重试该子任务或调整任务书后再委派一次。\n"
                + "- 【图片传递】你附着在消息里的图片会自动随 delegate_task 传给子 Agent（每轮都在），"
                + "不要声称“无法把图片发给子 Agent”；任务书里直接引用附图（如“将附图逐张转写为文字”）。"
                + "若图片在文件夹中（不在聊天里），先用 list_dir 拿到清单，再通过 image_paths 参数"
                + "把图片路径列表传入，子 Agent 将直接看到图片，无需自己逐张 read_file。\n"
                + "- 【分批委派图片·强制】分批委派处理图片时，每批必须经 image_paths 传【该批图片的"
                + "绝对路径子集】（先 list_dir 盘点，再按批切分路径列表）。聊天附着图在每次委派时"
                + "全量自动携带、【无法按批拆分】，故分批场景一律用 image_paths；"
                + "任务书涉及图片却一张图都没带的委派会被系统拦截退回，需补图后重试。\n"
                + "- 【文档传递·强制】委派涉及文档（docx/xlsx/pptx/pdf/doc 等）时，⛔ 必须用 "
                + "file_paths 参数传【文件路径】，由子 Agent 自己 read_file 读取"
                + "（它能把这些格式解析为文本+格式概要）。【绝不要自己先 read_file 再把全文抄进任务书】"
                + "——那会把整篇文档塞进你的上下文，既慢（大文档 prefill 可达数分钟）又易截断，"
                + "违背委派分工的意义。只有当你【不委派、自己直接处理】某文档时，才自己 read_file。\n"
                + "- 不要委派自己，也不要把整个任务原样转丢给子 Agent。"
            )
        }
        return base
    }
}


// ════════════════════════════════════════════════════════════
// MARK: - run_tool_loop 主引擎（loop.py L1157-2125 逐行为）
// ════════════════════════════════════════════════════════════

extension NativeAgentLoop {

    /// tool-calling 循环。事件流（AsyncStream，无界缓冲对齐 asyncio.Queue）；
    /// 消费方提前终止 = 客户端断开（Python agen.aclose() → CancelledError 静默语义）。
    ///
    /// 熔断双保险：轮次上限 + 连续 consecutiveFailLimit 轮工具全部失败。
    /// cancelCheck：为真时本轮开始前（未发起模型调用）yield cancelled 并返回。
    /// injectCheck：每轮开始前 drain 用户「思考中」插入的新消息；不打断当前轮，
    ///   下一轮开始读入；取出即清空。与 cancelCheck 共用同一检查点。
    public static func runToolLoop(
        model: String,
        messages: [[String: JSONValue]],
        toolsSpecList: [JSONValue],
        sandboxRoot: String,
        connector: any NativeChatConnector,
        authorizer: (any NativeToolAuthorizer)? = nil,
        maxRounds: Int = maxRoundsDefault,
        contextLimit: Int = 0,
        firstRoundImages: [String]? = nil,
        cancelCheck: (@Sendable () -> Bool)? = nil,
        injectCheck: (@Sendable () -> [String])? = nil,
        knowledgeCtx: NativeKnowledgeContext? = nil,
        archiveCtx: NativeArchiveContext? = nil,
        appControlCtx: NativeAppControlContext? = nil,
        computerUseCtx: NativeComputerUseContext? = nil,
        delegationCtx: NativeDelegationContext? = nil,
        skillReader: (any NativeSkillReader)? = nil,
        toolContext: NativeToolContext? = nil,
        toolExecutor: (any NativeLoopToolExecutor)? = nil,
        configProvider: (@Sendable () -> [String: JSONValue])? = nil,
        lazyTiers: NativeLazyCtxTiers? = nil
    ) -> AsyncStream<NativeAgentLoopEvent> {
        AsyncStream { continuation in
            let task = Task {
                let config: @Sendable () -> [String: JSONValue] = configProvider ?? { [:] }
                let tiers = lazyTiers ?? NativeLazyCtxTiers(configProvider: config)
                let executor: (any NativeLoopToolExecutor)? = toolExecutor
                    ?? toolContext.map {
                        NativeRegistryLoopToolExecutor(context: $0, authorizer: authorizer)
                    }
                await runMain(
                    model: model, messages: messages, toolsSpecList: toolsSpecList,
                    sandboxRoot: sandboxRoot, connector: connector,
                    maxRounds: maxRounds, contextLimit: contextLimit,
                    firstRoundImages: firstRoundImages,
                    cancelCheck: cancelCheck, injectCheck: injectCheck,
                    knowledgeCtx: knowledgeCtx, archiveCtx: archiveCtx,
                    appControlCtx: appControlCtx, computerUseCtx: computerUseCtx,
                    delegationCtx: delegationCtx, skillReader: skillReader,
                    executor: executor, config: config, lazyTiers: tiers,
                    continuation: continuation)
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    struct PendingToolCall {
        var id: String
        var name: String
        var args: [String: JSONValue]
    }

    private static func runMain(
        model: String,
        messages: [[String: JSONValue]],
        toolsSpecList: [JSONValue],
        sandboxRoot: String,
        connector: any NativeChatConnector,
        maxRounds: Int,
        contextLimit: Int,
        firstRoundImages: [String]?,
        cancelCheck: (@Sendable () -> Bool)?,
        injectCheck: (@Sendable () -> [String])?,
        knowledgeCtx: NativeKnowledgeContext?,
        archiveCtx: NativeArchiveContext?,
        appControlCtx: NativeAppControlContext?,
        computerUseCtx: NativeComputerUseContext?,
        delegationCtx: NativeDelegationContext?,
        skillReader: (any NativeSkillReader)?,
        executor: (any NativeLoopToolExecutor)?,
        config: @escaping () -> [String: JSONValue],
        lazyTiers: NativeLazyCtxTiers,
        continuation: AsyncStream<NativeAgentLoopEvent>.Continuation
    ) async {
        func emit(_ event: String, _ data: [String: JSONValue]) {
            continuation.yield(NativeAgentLoopEvent(event: event, data: data))
        }
        func stateData(step: Int, tokensUsed: Int, promptEval: Int, ctxChars: Int) -> [String: JSONValue] {
            ["step": .int(Int64(step)), "max": .int(Int64(maxRounds)),
             "tokens_used": .int(Int64(tokensUsed)),
             "prompt_eval_count": .int(Int64(promptEval)),
             "ctx_chars": .int(Int64(ctxChars))]
        }

        var msgs = messages
        var tokensUsed = 0
        var consecutiveFailRounds = 0
        var searchCircuitStrikes = 0          // TS-105：web_search 熔断计数
        // REQ-PERF-002 重复动作熔断状态（调用级，跨轮累计）：
        //   repeatSig = 最近一次失败/零进展调用的签名（工具名 + 参数紧凑 JSON）；
        //   repeatStrikes = 同签名连续失败/零进展次数。
        var repeatSig: String? = nil
        var repeatStrikes = 0
        // 阈值读取 config key agent.repeatActionFuse（业主给定键名，点号 camelCase 照用）：
        //   缺省 3；0 = 关闭；非法值（非数字/负数）→ 3；正数 clamp 最小 2——
        //   阈值 1 会误伤首次重试（一次失败即熔断过于激进），故最小 2。
        let repeatFuseLimit: Int = {
            guard let raw = config()["agent.repeatActionFuse"] else { return 3 }
            let n: Int
            switch raw {
            case .int(let i): n = Int(i)
            case .double(let d): n = Int(d)
            default: return 3
            }
            if n == 0 { return 0 }   // 显式关闭
            if n < 0 { return 3 }    // 负数非法 → 缺省
            return max(2, n)
        }()
        // 0.4.11：Computer Use 连败熔断计数（工具名 → 连续失败次数；截屏不计入）
        var computerUseStrikes: [String: Int] = [:]
        var toolCallsLog: [[String: JSONValue]] = []
        // #3（0.4.19）：full_text 必须在【轮次循环外】累积——done 带【完整】文本
        var fullText = ""
        var executedSearches: [String: Int] = [:]   // 归一化 query → 命中次数（去重缓存）
        var promptEvalHistory: [Int] = []           // M2 上下文预警（est_rounds_left 倒推）
        // checkpoint-067 R-4：read_file 读到的图片 base64，下一轮经 images 参数注入视觉流
        var pendingToolImages: [String] = []
        var contextLimit = contextLimit

        for step in stride(from: 1, through: maxRounds, by: 1) {
            if Task.isCancelled { return }   // 客户端断开：静默结束（CancelledError 同语义）
            // TS-114 检查点：每轮开始前（发起模型调用之前）检测取消标志
            if let cancelCheck, cancelCheck() {
                emit("cancelled", ["detail": .string("已停止")])
                return
            }
            // A5（0.4.16）：每轮开始前 drain 用户「思考中」插入的新消息。
            // 不打断当前轮；取出即清空。与 cancel_check 共用检查点。
            if let injectCheck {
                let injected = injectCheck()
                // #1（0.4.20）插入点分裂：先 yield segment_break（前端就地定格当前气泡），
                // 再并入上下文。只在真有新消息时发；payload 过滤空白。
                let payload: [JSONValue] = injected
                    .filter { !pyTrim($0).isEmpty }
                    .map { JSONValue.object(["role": .string("user"), "content": .string($0)]) }
                if !payload.isEmpty {
                    // break_at = 截至此刻已生成正文字符数（full_text 跨轮累加，done 是全文）
                    emit("segment_break", ["injected_messages": .array(payload),
                                           "break_at": .int(Int64(pyLen(fullText)))])
                }
                for t in injected where !pyTrim(t).isEmpty {
                    msgs.append(["role": .string("user"), "content": .string(t)])
                }
            }
            // 0.4.31（P1 懒加载升档，D3）：置于 90% 压缩预警【之前】，升档后回填
            // context_limit——确保只有到达【上限】后才触发压缩。est = ctx_chars×0.6。
            if contextLimit != 0 {
                let estTokens = Double(measureCtxChars(msgs, toolsSpecList)) * 0.6
                if lazyTiers.maybeBumpCtx(model, estTokens: estTokens),
                   let newTier = lazyTiers.currentCtxFor(model) {
                    contextLimit = newTier
                }
            }
            // M2 溢出预警（每轮开始前判定）
            if let lastPe = promptEvalHistory.last, contextLimit != 0,
               Double(lastPe) / Double(contextLimit) >= 0.90 {
                let recent = Array(promptEvalHistory.suffix(5))
                var est = -1
                if recent.count >= 2 {
                    var deltas: [Double] = []
                    for i in 0..<(recent.count - 1) {
                        deltas.append(Double(recent[i + 1] - recent[i]))
                    }
                    let avgDelta = deltas.reduce(0, +) / Double(deltas.count)
                    let remaining = contextLimit - lastPe
                    est = avgDelta > 0 ? Int(Double(remaining) / avgDelta) : -1
                }
                let data: [String: JSONValue] = [
                    "used": .int(Int64(lastPe)), "limit": .int(Int64(contextLimit)),
                    "est_rounds_left": .int(Int64(est)),
                ]
                if config()["allow_auto_compact"]?.bool ?? false {
                    // compact_auto = 通知服务端该压缩了；发事件即返回（不 continue 烧轮次）
                    emit("compact_auto", data)
                } else {
                    emit("compact_required", data)
                }
                return
            }

            var pendingTcs: [PendingToolCall] = []
            var stepPe = 0
            var stepEc = 0

            // M6（TS-112）图片入流；checkpoint-067 R-4：工具读到的图片合并注入。
            // checkpoint-070：用户附着图片【每轮都重发】（不能只发第一轮）。
            var imgs: [String] = []
            if let firstRoundImages { imgs += firstRoundImages }   // 用户附着图片：每轮重发
            if !pendingToolImages.isEmpty {
                imgs += pendingToolImages                          // 工具读到的图片：注入后即清空
                pendingToolImages = []
            }
            // B3（0.4.8）：本轮送入模型的真实上下文字数（轮初统计；轮末 state 前重算）
            let ctxChars = measureCtxChars(msgs, toolsSpecList)

            do {
                for try await ev in connector.chatStream(
                    model: model, messages: msgs,
                    tools: toolsSpecList, images: imgs.isEmpty ? nil : imgs) {
                    if Task.isCancelled { return }   // 客户端断开：静默结束
                    switch ev {
                    case .streamError(let se):
                        // connector 兜底的流内超时 → 优雅结束（带失败明细 + 诊断）
                        emit("error", await buildErrorPayload(
                            "流式推理中断：\(se)", toolCallsLog,
                            connector: connector, config: config))
                        return
                    case .contentDelta(let delta):
                        fullText += delta
                        emit("token", ["delta": .string(delta)])
                    case .thinkingDelta(let delta):
                        // TS-102 B13：思考增量透传（不计入正文/上下文）
                        emit("thinking", ["delta": .string(delta)])
                    case .toolCalls(let tcs):
                        for tc in tcs {
                            let fn = tc["function"]?.object ?? [:]
                            var args: [String: JSONValue] = [:]
                            if let raw = fn["arguments"] {
                                if let s = raw.string {
                                    if let d = s.data(using: .utf8),
                                       let v = NativeJSONWriter.loads(d),
                                       case .object(let o) = v {
                                        args = o
                                    }
                                } else if case .object(let o) = raw {
                                    args = o
                                }
                            }
                            let rawId = tc["id"]?.string ?? ""
                            pendingTcs.append(PendingToolCall(
                                id: rawId.isEmpty ? "call_\(pendingTcs.count + 1)" : rawId,
                                name: fn["name"]?.string ?? "",
                                args: args))
                        }
                    case .done(let pe, let ec):
                        stepPe = pe
                        stepEc = ec
                    }
                }
            } catch {
                // 偏差①：app.py gen() 最终安全网等价——业务/网络异常转 error 事件
                // （P3-W2b：NativeNetworkGuardError 同列——Python gen() 把
                // NetworkGuardError/OllamaAPIError 一并转 e.message 事件）
                let message = (error as? NativeChatConnectorError)?.message
                    ?? (error as? NativeNetworkGuardError)?.message
                    ?? error.localizedDescription
                emit("error", await buildErrorPayload(
                    "模型请求失败：\(message)", toolCallsLog,
                    connector: connector, config: config))
                return
            }

            tokensUsed += stepPe + stepEc
            if stepPe > 0 { promptEvalHistory.append(stepPe) }

            if pendingTcs.isEmpty {
                // 最后一轮插入补救（0.4.23）：done 之前补 drain 一次——用户在【最后一轮】
                // 生成途中插入的消息，发 segment_break + 并入 msgs + continue 让模型真读到
                // （保住 A5「不打断当前轮、下一轮读到」语义）。必须守 step < maxRounds：
                // 轮次预算耗尽时 continue 会掉出循环走到「达到最大轮次」error，
                // 把正常完成变成报错；此时如实保留 done，接受残留限制。
                if let injectCheck, step < maxRounds {
                    let finalInjected = injectCheck()
                    let payload: [JSONValue] = finalInjected
                        .filter { !pyTrim($0).isEmpty }
                        .map { JSONValue.object(["role": .string("user"), "content": .string($0)]) }
                    if !payload.isEmpty {
                        emit("segment_break", ["injected_messages": .array(payload),
                                               "break_at": .int(Int64(pyLen(fullText)))])
                        for t in finalInjected where !pyTrim(t).isEmpty {
                            msgs.append(["role": .string("user"), "content": .string(t)])
                        }
                        continue   // 不 yield done：下一轮正常流程接管
                    }
                }
                if !pyTrim(fullText).isEmpty {
                    emit("state", stateData(step: step, tokensUsed: tokensUsed,
                                            promptEval: stepPe, ctxChars: ctxChars))
                    emit("done", ["content": .string(fullText),
                                  "tool_calls": .array(toolCallsLog.map { .object($0) })])
                    return
                }
                // 空回复（模型未说话也没调工具）→ 优雅报错，不无限转
                emit("error", await buildErrorPayload(
                    "模型未返回任何内容（无文本且无工具调用），已停止。当前模型：\(model)。"
                    + "常见原因：该模型在工具结果回注后直接输出空（立即结束），属模型层稳定性问题。",
                    toolCallsLog, connector: connector, config: config))
                return
            }

            var allFailed = true
            for tc in pendingTcs {
                emit("tool_call", ["id": .string(tc.id), "name": .string(tc.name),
                                   "args": .object(tc.args), "status": .string("running")])

                // ---- 2026-08-28 问题2：web_search 去重拦截 ----
                // 相同关键词重复搜索不再真实执行，直接返回提示引导基于已有结果作答。
                if tc.name == "web_search" {
                    let q = normalizeQuery(tc.args["query"]?.string ?? "")
                    if !q.isEmpty, executedSearches[q] != nil {
                        let n = (executedSearches[q] ?? 0) + 1
                        executedSearches[q] = n
                        let errMsg = "duplicate_search: 关键词「\(tc.args["query"]?.string ?? q)」"
                            + "已在本会话搜索过（第 \(n) 次重复）。"
                            + "请勿重复搜索同一/相近关键词，直接基于之前返回的搜索结果整理回答；"
                            + "若信息不足，请换一个明显不同的角度重新拟定关键词。"
                        // 重复搜索视为未获得新信息，计入失败（连续重复触发熔断防死循环）
                        let entry: [String: JSONValue] = [
                            "id": .string(tc.id), "name": .string(tc.name),
                            "ok": .bool(false), "summary": .string("重复搜索已拦截"),
                            "error": .string(errMsg),
                        ]
                        toolCallsLog.append(entry)
                        emit("tool_result", ["id": .string(tc.id), "name": .string(tc.name),
                                             "ok": .bool(false),
                                             "summary": .string("重复搜索已拦截"),
                                             "error": .string(errMsg)])
                        let report: [String: JSONValue] = ["tool_report": .object([
                            "id": .string(tc.id), "name": .string(tc.name),
                            "args": .object(tc.args),
                            "result": .object(["ok": .bool(false), "error": .string(errMsg)]),
                        ])]
                        msgs.append(["role": .string("user"),
                                     "content": .string(dumps(.object(report)))])
                        continue   // 不执行真实搜索
                    }
                }

                // ---- 路由（delegate_task / read_skill / search_knowledge /
                //   archive_work_unit / app_control / CU 工具组 / cu_macro 工具组
                //   已在分支内处理，跳过通用执行——loop.py L2027-2031 同款纪律）----
                var result: [String: JSONValue]
                switch tc.name {
                case "read_skill":
                    result = routeReadSkill(args: tc.args, reader: skillReader)
                case "app_control":
                    result = await routeAppControl(args: tc.args, ctx: appControlCtx,
                                                   sandboxRoot: sandboxRoot, config: config)
                case "screen_view", "mouse_click", "keyboard_type", "keyboard_hotkey",
                     "element_locate":
                    result = await routeComputerUse(tc: tc, ctx: computerUseCtx,
                                                    strikes: &computerUseStrikes)
                case "cu_macro_record", "cu_macro_replay", "cu_macro_list":
                    // 0.4.33：宏工具不计入 computer_use_strikes（语义错误非硬件连败）
                    result = await routeComputerUseMacro(tc: tc, ctx: computerUseCtx)
                case "archive_work_unit":
                    result = routeArchive(args: tc.args, ctx: archiveCtx)
                case "search_knowledge":
                    result = routeSearchKnowledge(args: tc.args, ctx: knowledgeCtx)
                case "delegate_task":
                    result = await routeDelegate(tc: tc, ctx: delegationCtx,
                                                 sandboxRoot: sandboxRoot,
                                                 maxRounds: maxRounds,
                                                 firstRoundImages: firstRoundImages)
                default:
                    // 通用执行：NativeToolRegistry（authorizer 仅透传 registry 层判定——
                    // 2026-08-28 权限宽松化：loop 层不再每次调用前询问）
                    if let executor {
                        result = await executor.executeLoopTool(tc.name, args: tc.args,
                                                                sandboxRoot: sandboxRoot)
                    } else {
                        result = err("工具执行器未装配（NativeToolContext 缺失），无法执行: \(tc.name)")
                    }
                }

                let ok = result["ok"] == .bool(true)
                if ok {
                    allFailed = false
                    // 记录成功执行的搜索关键词（供后续去重）
                    if tc.name == "web_search" {
                        let q = normalizeQuery(tc.args["query"]?.string ?? "")
                        if !q.isEmpty, executedSearches[q] == nil { executedSearches[q] = 0 }
                    }
                    // checkpoint-067 R-4：read_file 读到图片 → 收集 base64 供下一轮
                    // 视觉注入，并从回注报告剔除巨大 base64（图片走 images 参数）。
                    if result["_kind"] == .string("image"), let b64 = result["image_base64"]?.string {
                        var mime = result["mime"]?.string ?? "image/png"
                        if !mime.hasPrefix("image/") { mime = "image/png" }
                        pendingToolImages.append("data:\(mime);base64,\(b64)")
                        result = result.filter { $0.key != "image_base64" && $0.key != "mime" }
                    }
                }
                var entry: [String: JSONValue] = [
                    "id": .string(tc.id), "name": .string(tc.name), "ok": .bool(ok),
                    "summary": .string(summarize(result)),
                ]
                // 0.4.9 任务161：失败时记录参数摘要（哪个工具、什么参数），逐值截断 80 字
                if !ok {
                    entry["error"] = .string(result["error"]?.string ?? "unknown")
                    var brief: [String: JSONValue] = [:]
                    for k in tc.args.keys.sorted().prefix(6) {
                        let v = tc.args[k]!
                        switch v {
                        case .int, .double, .bool:
                            brief[k] = v   // isinstance(int/float/bool) → 原样保留
                        case .string(let s):
                            brief[k] = .string(pyPrefix(s, 80))
                        default:
                            brief[k] = .string(pyPrefix(WFText.pyStr(v), 80))
                        }
                    }
                    entry["args"] = .object(brief)
                }
                toolCallsLog.append(entry)
                var trData: [String: JSONValue] = [
                    "id": .string(tc.id), "name": .string(tc.name), "ok": .bool(ok),
                    "summary": entry["summary"] ?? .string(""),
                    "error": entry["error"] ?? .null,
                ]
                // TS-108：委派结果中的 created_agent（自动新建标注）透出事件流
                if tc.name == "delegate_task", let ca = result["created_agent"] {
                    trData["created_agent"] = ca
                }
                emit("tool_result", trData)
                // REQ-PERF-002 重复动作熔断（0.7.4 W3，调用级、跨轮累计）：
                // 保守红线——只有 ok==false 或结果显式带 zero_progress=true
                // （预留缝，现无工具产出该标记）才计数；成功或参数不同一律清零重计。
                // web_search 去重拦截分支（上方 continue）不走这里，不计入本熔断。
                // 与「连续 2 轮全败」轮级熔断不冲突：那是轮粒度，这是同参数调用粒度。
                if repeatFuseLimit > 0 {
                    let zeroProgress = ok && result["zero_progress"] == .bool(true)
                    if !ok || zeroProgress {
                        let sig = tc.name + "\n" + Self.dumps(.object(tc.args))
                        if sig == repeatSig {
                            repeatStrikes += 1
                        } else {
                            repeatSig = sig
                            repeatStrikes = 1
                        }
                        if repeatStrikes >= repeatFuseLimit {
                            emit("error", await buildErrorPayload(
                                "重复动作熔断：工具「\(tc.name)」以相同参数连续失败 \(repeatStrikes) 次，"
                                + "已暂停本轮执行以避免无效循环。若属正常重试（如在等待外部状态变化），"
                                + "请告知我继续；否则建议调整参数或换个做法。",
                                toolCallsLog, connector: connector, config: config))
                            return
                        }
                    } else {
                        repeatStrikes = 0
                        repeatSig = nil
                    }
                }
                // TS-105 熔断感知停止：web_search 返回 circuit_open=True → 立即停止。
                // 判定放在 yield tool_result 之后，确保前端能看到最后一次工具结果。
                if tc.name == "web_search" {
                    if result["circuit_open"] == .bool(true) {
                        searchCircuitStrikes += 1
                        if searchCircuitStrikes >= searchCircuitStop {
                            emit("error", await buildErrorPayload(
                                "境外搜索已被系统熔断（无代理环境下重复重试无意义）。已停止。"
                                + "请开启代理或改用国内信息源后重试。",
                                toolCallsLog, connector: connector, config: config))
                            return
                        }
                    } else {
                        searchCircuitStrikes = 0
                    }
                }
                // 结果回注：qwen 系不解析 role="tool" → role=user 内嵌结构化 JSON 工具报告
                let report: [String: JSONValue] = ["tool_report": .object([
                    "id": .string(tc.id),
                    "name": .string(tc.name),
                    "args": .object(tc.args),
                    "result": .object(result),
                    "note": .string("以上是工具执行结果（结构化 JSON）。ok=false 时按 error 字段处理，不要重试同一错误调用。"),
                ])]
                msgs.append(["role": .string("user"),
                             "content": .string(dumps(.object(report)))])
            }

            // 0.4.22（checkpoint-109）：轮末 state 前**重算** ctx_chars——
            // 本轮新增的 tool_report / 注入消息必须进指示器。
            let ctxCharsEnd = measureCtxChars(msgs, toolsSpecList)
            emit("state", stateData(step: step, tokensUsed: tokensUsed,
                                    promptEval: stepPe, ctxChars: ctxCharsEnd))

            // 双保险熔断之 2：连续失败
            if allFailed {
                consecutiveFailRounds += 1
                if consecutiveFailRounds >= consecutiveFailLimit {
                    emit("error", await buildErrorPayload(
                        "连续工具失败：连续 \(consecutiveFailLimit) 轮工具调用全部失败，已停止。",
                        toolCallsLog, connector: connector, config: config))
                    return
                }
            } else {
                consecutiveFailRounds = 0
            }
        }

        // 双保险熔断之 1：轮次上限
        emit("error", await buildErrorPayload(
            "达到最大轮次（\(maxRounds)），已停止。已完成部分见上方 tool_result。",
            toolCallsLog, connector: connector, config: config))
    }
}


// ════════════════════════════════════════════════════════════
// MARK: - 工具路由分支（loop.py 各 if tc["name"] == ... 块逐行为）
// ════════════════════════════════════════════════════════════

extension NativeAgentLoop {

    // MARK: read_skill（TS-110 M4：只读，不执行任何指令）

    static func routeReadSkill(args: [String: JSONValue],
                               reader: (any NativeSkillReader)?) -> [String: JSONValue] {
        let name = pyTrim(args["name"]?.string ?? "")
        guard let reader else {
            // W4c 起 skills 已原生接管；reader 为 nil 属装配缺失——如实报错，不静默吞
            return err("技能读取执行器未装配（NativeSkillsManager 未注入会话上下文）")
        }
        guard let sk = name.isEmpty ? nil : reader.readSkill(name) else {
            let names = reader.listSkillNames().joined(separator: "、")
            return err("技能不存在：\(name)。当前可用技能：\(names.isEmpty ? "（暂无技能）" : names)")
        }
        guard sk.enabled else {
            // checkpoint-047：逐项开关——该技能被用户禁用
            return err("技能「\(name)」已被禁用（设置 → 插件与技能），无法调用。")
        }
        return ["ok": .bool(true), "_kind": .string("read_skill"),
                "name": .string(sk.dirName), "description": .string(sk.description),
                "content": .string(sk.content)]
    }

    // MARK: search_knowledge（TS-120 阶段二：拉模式；结果本轮用完即弃）

    static func routeSearchKnowledge(args: [String: JSONValue],
                                     ctx: NativeKnowledgeContext?) -> [String: JSONValue] {
        let q = pyTrim(args["query"]?.string ?? "")
        if q.isEmpty {
            return err("search_knowledge 需要 query 参数（检索词）")
        }
        guard let ctx else {
            return err("当前会话未启用知识仓库检索")
        }
        let scope = pyTrim(args["scope"]?.string ?? "all")
        let mode = pyTrim(args["mode"]?.string ?? "hybrid")
        // int(limit or 5) clamp(1,20)；TypeError/ValueError → 5
        let limit: Int = {
            var base = 5
            if let raw = args["limit"], raw != .null {
                if let i = raw.int {
                    base = Int(i)
                } else if let d = raw.double {
                    base = Int(d)
                } else if let s = raw.string,
                          let i = Int(s.trimmingCharacters(in: .whitespaces)) {
                    base = i
                } else {
                    return 5
                }
            }
            if base == 0 { base = 5 }   // Python `or` 语义：0 为 falsy
            return max(1, min(base, 20))
        }()
        let hits = ctx.searcher.searchScoped(q, scope: scope, projectId: ctx.projectId,
                                             limit: limit, mode: mode)
        let items: [JSONValue] = hits.map { h in
            .object([
                "title": h.title.map { .string($0) } ?? .null,
                "scope": h.scope.map { .string($0) } ?? .null,
                "score": h.score.map { .double($0) } ?? .null,
                "body": .string(pyPrefix(h.body, 2000)),
            ])
        }
        return ["ok": .bool(true), "_kind": .string("knowledge"),
                "count": .int(Int64(items.count)), "items": .array(items),
                "note": .string("检索结果仅本轮可见，不会写入对话上下文。")]
    }

    // MARK: archive_work_unit（0.4.9 3.47.1；W4c 已接管：NativeWorkUnitArchiveExecutor）

    static func routeArchive(args: [String: JSONValue],
                             ctx: NativeArchiveContext?) -> [String: JSONValue] {
        let title = pyTrim(args["title"]?.string ?? "")
        let summary = pyTrim(args["summary"]?.string ?? "")
        if title.isEmpty {
            return err("archive_work_unit 需要 title 参数（工作单元名称，如'《某案件》案情分析'）")
        }
        guard let ctx else {
            return err("当前会话未开启「单元归档」（工具不应出现在列表中）。"
                + "请如实告知用户：需在会话窗工具栏开启该开关后才能归档。")
        }
        guard let archiver = ctx.archiver else {
            return err("单元归档执行器未装配（NativeWorkUnitArchiveExecutor 未注入会话上下文）")
        }
        return archiver.archiveWorkUnit(projectId: ctx.projectId, sessionId: ctx.sessionId,
                                        title: title, summary: summary,
                                        scope: args["scope"]?.string ?? "project")
    }

    // MARK: app_control（0.4.9 3.48.2；W4c 已接管：NativeAppModuleRegistry）

    static func routeAppControl(args: [String: JSONValue],
                                ctx: NativeAppControlContext?,
                                sandboxRoot: String,
                                config: () -> [String: JSONValue]) async -> [String: JSONValue] {
        let module = pyTrim(args["module"]?.string ?? "")
        let action = pyTrim(args["action"]?.string ?? "")
        let params: [String: JSONValue] = args["params"]?.object ?? [:]
        if module.isEmpty || action.isEmpty {
            return err("app_control 需要 module 与 action 两个参数"
                + "（见系统提示词【可用应用模块动作】清单）。")
        }
        guard let ctx else {
            return err("当前会话未启用应用内模块控制（工具不应出现在列表中）。"
                + "请如实告知用户：需在 设置 → 应用内模块控制 开启后才能调用。")
        }
        guard let dispatcher = ctx.dispatcher else {
            return err("应用内模块控制分发链路尚未原生接管（P2-W4c 排期）")
        }
        // config app_control_confirm：非 list → None（Python isinstance 判定）
        let confirmList = config()["app_control_confirm"]?.stringArray
        let needConfirm = dispatcher.actionNeedsConfirm(module, action, confirmList: confirmList)
        var denied = false
        var result: [String: JSONValue] = [:]
        if needConfirm {
            // 副作用动作（运行工作流 / 创建圆桌）：先弹窗请用户确认。
            // 复用敏感操作授权通道（action="app_module"）。
            if ctx.authorizer == nil {
                result = err("app_module_denied: 「\(module).\(action)」属高成本操作需用户确认，"
                    + "但当前无授权通道，已拒绝执行（不擅自运行工作流/创建圆桌）。")
                denied = true
            } else if let authorizer = ctx.authorizer {
                let detail = pyPrefix(dumps(.object(params)), 400)
                let allowed = await authorizer.authorize(
                    tool: "app_control:\(module).\(action)", path: detail, action: "app_module")
                if !allowed {
                    result = err("denied_by_user: 用户拒绝了「\(module).\(action)」。"
                        + "不要再重试该动作，请如实告知用户已取消，并询问下一步怎么做。")
                    denied = true
                }
            }
        }
        if !denied {
            result = await dispatcher.dispatch(
                module, action, params: params,
                projectId: ctx.projectId, sessionId: ctx.sessionId,
                sandboxRoot: ctx.sandboxRoot.isEmpty ? sandboxRoot : ctx.sandboxRoot)
        }
        return result
    }

    // MARK: Computer Use 动作工具（0.4.9 3.48.1 + 0.4.11 连败熔断；执行器 W4c 注入）

    static func routeComputerUse(
        tc: PendingToolCall,
        ctx: NativeComputerUseContext?,
        strikes: inout [String: Int]
    ) async -> [String: JSONValue] {
        guard let ctx else {
            return err("当前会话未启用 Computer Use（工具不应出现在列表中）。"
                + "请如实告知用户：需在 设置 → Computer Use 开启总开关后才能操作电脑。")
        }
        guard let executor = ctx.executor else {
            return err("Computer Use 执行链路尚未原生接管（P2-W4c 排期）")
        }
        // 0.4.11 连败熔断：必须在【白名单 / 权限 / 确认弹窗】之前判断（真机事故教训）
        let cur = strikes[tc.name] ?? 0
        if cur >= computerUseMaxStrikes {
            strikes[tc.name] = cur + 1
            return err("computer_use_circuit_open: 「\(tc.name)」已连续失败 \(cur) 次，"
                + "本轮已熔断该动作，不再重试、也不再弹确认窗。\n"
                + "⛔ 不要换参数重试同一动作，也不要改用其他 Computer Use 动作绕过。"
                + "请如实告知用户：该动作连续失败、需人工介入排查"
                + "（最常见根因是辅助功能/屏幕录制权限未授予本应用——原生架构无侧车，事件由本进程发出；"
                + "让用户到 设置 → Computer Use 点「检测权限」查看确切路径与逐步指引）。")
        }
        let result = await executor.executeComputerUse(tc.name, args: tc.args)
        // 0.4.11 熔断结算：成功即清零（连败要求"连续"）；失败累加。
        // 用户主动拒绝也计入——连拒两次说明该动作不该继续，停止骚扰用户。
        strikes[tc.name] = (result["ok"] == .bool(true)) ? 0 : cur + 1
        return result
    }

    // MARK: Computer Use 任务宏（0.4.33 R1；不计入连败熔断）

    static func routeComputerUseMacro(
        tc: PendingToolCall,
        ctx: NativeComputerUseContext?
    ) async -> [String: JSONValue] {
        guard let ctx else {
            return err("当前会话未启用 Computer Use（工具不应出现在列表中）。"
                + "请如实告知用户：需在 设置 → Computer Use 开启总开关后才能操作电脑。")
        }
        guard let executor = ctx.executor else {
            return err("Computer Use 执行链路尚未原生接管（P2-W4c 排期）")
        }
        return await executor.executeComputerUse(tc.name, args: tc.args)
    }

    // MARK: delegate_task（TS-107 M3-1；W4b 真实现：NativeDelegationEngine 注入）

    static func routeDelegate(
        tc: PendingToolCall,
        ctx: NativeDelegationContext?,
        sandboxRoot: String,
        maxRounds: Int,
        firstRoundImages: [String]?
    ) async -> [String: JSONValue] {
        guard let ctx else {
            // delegation_ctx 为 None（子会话/旧端点）→ 双保险拒绝
            return err("当前会话不允许委派")
        }
        guard let runner = ctx.runner else {
            // 生产装配恒注入 kernel.delegationEngine（NativeKernel lazy 非可选），
            // 本分支仅测试缝可达——HTTP 侧车已随 P3-W6 归零，不再给绕行指引。
            return err("委派执行链路未装配（原生内核未注入委派引擎）——"
                + "请如实告知用户委派暂不可用，不要重试")
        }
        do {
            return try await runner.routeDelegateTask(
                args: tc.args, projectId: ctx.projectId, agentId: ctx.agentId,
                sessionId: ctx.sessionId, parentModel: ctx.model ?? "",
                sandboxRoot: sandboxRoot, maxRounds: maxRounds,
                firstRoundImages: firstRoundImages)
        } catch is CancellationError {
            // 客户端停止主会话（Python CancelledError 穿透 run_tool_loop 由 app.py
            // 收尾等价）：原生 loop 自包含，转错误结果并在下一轮开始被
            // Task.isCancelled 检查终止（偏差⑥，汇报清单同步）。
            return err("委派被中断（用户停止或连接断开）")
        } catch {
            return err("委派执行出错：\(error)")
        }
    }
}
