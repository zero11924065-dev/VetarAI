//
//  ChatModels.swift
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

//  会话面板纯逻辑层（无 UI / 无网络依赖，全部可单测）。
//  每个函数都对照 subagent/renderer/src/panels/ChatPanel.tsx 的同名实现逐字移植，
//  数值/文案口径以现状代码为准（纪律④）。
//

import Foundation

// MARK: - 输入归一化（B1 0.4.12）

/// 判空与内容保真共用同一套规则（现状 normalizeInputText）：
/// 只剔真正的不可见字符（零宽/BOM/软连字符）；\u00A0 降级为普通空格；换行与词间空格保留。
public func normalizeInputText(_ raw: String) -> String {
    var s = raw
    for ch in ["\u{200B}", "\u{200C}", "\u{200D}", "\u{200E}", "\u{200F}", "\u{2060}", "\u{FEFF}", "\u{00AD}"] {
        s = s.replacingOccurrences(of: ch, with: "")
    }
    return s.replacingOccurrences(of: "\u{00A0}", with: " ")
}

/// 发送可用性唯一判据：按钮 disabled 与发送守卫必须调同一个函数（现状 hasSendableText）。
public func hasSendableText(_ raw: String) -> Bool {
    !normalizeInputText(raw).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
}

// MARK: - 流式消息 id（TS-102 B14：单调序号，同一毫秒内不重复）

public enum LocalMessageID {
    private static var seq = 0
    public static func next() -> String {
        seq += 1
        return "local_\(Int(Date().timeIntervalSince1970 * 1000))_\(seq)"
    }
}

// MARK: - 时间戳格式化（TS-116 3.28）

/// SQLite datetime('now') 是 UTC，补 'Z' 解析；刚刚 / N 分钟前 / 今天 HH:mm / 昨天 HH:mm / MM-dd HH:mm。
public func formatChatTime(_ isoString: String, now: Date = Date()) -> String {
    guard !isoString.isEmpty else { return "" }
    var s = isoString
    if !s.contains("T") { s = s.replacingOccurrences(of: " ", with: "T") + "Z" }
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    var date = f.date(from: s)
    if date == nil {
        f.formatOptions = [.withInternetDateTime]
        date = f.date(from: s)
    }
    guard let date else { return "" }
    let diffMins = Int(now.timeIntervalSince(date) / 60)
    if diffMins < 1 { return "刚刚" }
    if diffMins < 60 { return "\(diffMins) 分钟前" }
    let cal = Calendar.current
    let timeFmt = DateFormatter()
    timeFmt.locale = Locale(identifier: "zh_CN")
    timeFmt.dateFormat = "HH:mm"
    if cal.isDate(date, inSameDayAs: now) { return timeFmt.string(from: date) }
    if let yesterday = cal.date(byAdding: .day, value: -1, to: now),
       cal.isDate(date, inSameDayAs: yesterday) {
        return "昨天 \(timeFmt.string(from: date))"
    }
    let dayFmt = DateFormatter()
    dayFmt.locale = Locale(identifier: "zh_CN")
    dayFmt.dateFormat = "MM-dd HH:mm"
    return dayFmt.string(from: date)
}

// MARK: - 上下文估算（M2 / B3 0.4.8 / 问题4）

/// 对未归档消息文本做 token 估计（与现状 estimateContextTokens 同口径）：
/// 后端真实字数（state 事件 ctx_chars）优先（同一 0.6 系数）；否则按 user/assistant
/// 未归档消息字符数 × 0.6 启发式。目的不是精确计费，是让用户看到上下文压力。
public func estimateContextTokens(messages: [ChatMessage], backendCtxChars: Int) -> Int {
    if backendCtxChars > 0 { return Int((Double(backendCtxChars) * 0.6).rounded()) }
    var total = 0
    for m in messages {
        if m.archived { continue }
        guard m.role == "user" || m.role == "assistant" else { continue }
        total += Int((Double(m.content.count) * 0.6).rounded())
    }
    return total
}

/// A/B-2（0.4.23）：消息移入知识仓库后重算指示器（现状 ctxTokensAfterArchive 逐字移植）。
/// - 无后端真值（backendCtxChars ≤ 0）→ 不扣减，返回 {0, nil}（交回启发式兜底）。
/// - 扣到 0 → nextTokenUsed = nil（不硬显示 0，交回估算）。
public func ctxTokensAfterArchive(backendCtxChars: Int, messages: [ChatMessage],
                                  archivedDbIds: Set<Int>) -> (nextCtxChars: Int, nextTokenUsed: Int?) {
    guard backendCtxChars > 0 else { return (0, nil) }
    let archivedChars = messages
        .filter { $0.dbId.map { archivedDbIds.contains($0) } ?? false }
        .reduce(0) { $0 + $1.content.count }
    let nextCtxChars = max(0, backendCtxChars - archivedChars)
    return (nextCtxChars, nextCtxChars > 0 ? Int((Double(nextCtxChars) * 0.6).rounded()) : nil)
}

// MARK: - 工具步骤收敛（C2 根因③ / 0.4.22 checkpoint-109）

/// 把 running 态步骤收敛为 interrupted（现状 convergeRunningSteps 逐字移植）。
/// 五个出口共用：手动停止 ×3 / segment_break 定格 / done 兜底（重连丢 tool_result 时）。
public func convergeRunningSteps(_ steps: [ToolStep]) -> [ToolStep] {
    guard steps.contains(where: { $0.status == .running }) else { return steps }
    return steps.map { st in
        guard st.status == .running else { return st }
        var s = st
        s.status = .interrupted
        return s
    }
}

// MARK: - 思考预览（0.4.33 F3：单行钳制 + 悬浮看全文）

/// 思考预览只留末尾 120 字（现状 thinkingPreview slice(-120)）。
public func appendThinkingPreview(_ preview: String, delta: String) -> String {
    String((preview + delta).suffix(120))
}

// MARK: - Token 指示器（R3 0.4.33 / 0.4.31 D4 口径）

public struct TokenIndicatorState: Equatable {
    public var used: Int = 0
    public var limit: Int = 0        // 懒加载时为当前档
    public var ceiling: Int = 0      // 懒加载用户上限（0 = 单值显示）
    public var source: String = ""

    /// R3：懒加载生效 → 主除数 = 用户上限 ceiling；否则 limit。
    public var divisor: Int { ceiling > 0 ? ceiling : limit }
    public var ratio: Double { divisor > 0 ? Double(used) / Double(divisor) : 0 }

    /// 三档颜色（现状 tokenBarColor：≥0.99 danger / ≥0.90 warn / else ok）。
    public enum BarLevel: Equatable { case ok, warn, danger }
    public var barLevel: BarLevel {
        if ratio >= 0.99 { return .danger }
        if ratio >= 0.90 { return .warn }
        return .ok
    }

    /// 千分位统一格式化（业主 2026-09-29 拍板：「已用 9,307」有逗号而上限
    /// 262144 无逗号，同一行两种格式——统一全部带千分位分组）。
    private static func fmt(_ v: Int) -> String {
        v.formatted(.number.grouping(.automatic))
    }

    /// 顶栏文案（现状逐字+千分位统一）：上下文 ≈{used} / {ceiling||limit}（当前档 {limit}）
    public var displayText: String {
        let main = ceiling > 0 ? ceiling : limit
        var t = "上下文 ≈\(Self.fmt(used)) / \(Self.fmt(main))"
        if ceiling > 0 { t += "（当前档 \(Self.fmt(limit))）" }
        return t
    }

    /// 悬浮提示（现状 title 逐字+千分位统一）。
    public var tooltip: String {
        if ceiling > 0 {
            return "当前会话上下文估算：约 \(Self.fmt(used)) / 上限 \(Self.fmt(ceiling))（懒加载：当前档 \(Self.fmt(limit))，上下文膨胀自动升档直至上限；按未移入仓库的对话实时估算，非模型精确计费口径）"
        }
        return "当前会话上下文估算：约 \(Self.fmt(used)) / 上限 \(Self.fmt(limit))（按未移入仓库的对话实时估算，移入仓库后即下降；非模型精确计费口径）"
    }

    /// limit==0 且 source==error 时显示「上下文：获取失败」。
    public var failedText: String? {
        (limit == 0 && source == "error") ? "上下文：获取失败" : nil
    }
}

// MARK: - 工具步骤组文案（B4 0.4.12 / C8 0.4.16 / checkpoint-060）

public enum ToolStepsCopy {
    /// 单条步骤标签（现状 ToolStepBar label 逐字）。
    public static func stepLabel(_ step: ToolStep) -> String {
        switch step.status {
        case .running:     return "正在调用 \(step.name)…"
        case .interrupted: return "\(step.name)（已中断，未完成）"
        case .ok:          return "\(step.name) 完成（\(step.summary ?? "ok")）"
        case .error:       return "\(step.name) 失败：\(step.error ?? "unknown")"
        }
    }

    /// 整组头标签（现状 ToolStepsGroup headLabel 逐字）。
    /// interrupted 既不算 running（折叠判据）也不算 failed（警示色谎报）。
    public static func groupLabel(steps: [ToolStep], collapsed: Bool) -> String {
        let running = steps.filter { $0.status == .running }.count
        let failed = steps.filter { $0.status == .error }.count
        let okCount = steps.filter { $0.status == .ok }.count
        let interrupted = steps.filter { $0.status == .interrupted }.count
        if collapsed {
            if failed > 0 {
                var t = "工具调用 \(steps.count) 步 · \(okCount) 成功 · \(failed) 失败"
                if interrupted > 0 { t += " · \(interrupted) 中断" }
                return t
            }
            if interrupted > 0 { return "工具调用 \(steps.count) 步 · \(okCount) 成功 · \(interrupted) 中断" }
            return "工具调用 \(steps.count) 步 · 已完成"
        }
        if running > 0 { return "正在调用工具（\(running)/\(steps.count) 进行中）…" }
        return "工具调用 \(steps.count) 步"
    }

    /// 折叠判据（现状 shouldCollapse = done && running === 0）。
    public static func shouldCollapse(steps: [ToolStep], streamDone: Bool) -> Bool {
        streamDone && !steps.contains { $0.status == .running }
    }
}

// MARK: - 附件（checkpoint-048 / C3·C7 0.4.18 / 表#6 拉模式）

/// 附件正文注入的唯一分隔标记（现状 ATTACH_MARK；不可在别处写字面量副本）。
public let ATTACH_MARK = "--- 附件内容 ---"

/// 暂存区附件项（现状 PendingItem 的文档/图片子集；音频链待 ASR 模型包移植，见 ChatViewModel）。
public struct PendingAttachment: Identifiable, Equatable {
    public enum Kind { case image, file }
    public let id: String
    public var name: String
    public var kind: Kind
    public var size: Int
    /// 图片：dataURI（直接进请求 images 与气泡展示）；文件：base64 原文（解析用）
    public var dataURI: String
    // 解析三态（现状：解析中… / 已提取 /（仅文件名））
    public var parsing: Bool = false
    public var parsedText: String?
    public var parseFailed: Bool = false
    /// C7：后端落盘绝对路径（拉模式正文注入；解析失败但已落盘也要保留）
    public var savedPath: String?

    public init(name: String, kind: Kind, size: Int, dataURI: String) {
        self.id = "\(name)#\(UUID().uuidString.prefix(8))"
        self.name = name
        self.kind = kind
        self.size = size
        self.dataURI = dataURI
    }
}

public enum AttachmentComposer {
    /// 用户气泡正文（现状 handleSend parts 逐字）：
    /// 文本 + [📎 N 张图片已附加] + [📄 name]…（音频链待移植，不含 🎤 段）。
    public static func userBubbleText(text: String, hasText: Bool,
                                      imageCount: Int, fileNames: [String]) -> String {
        var parts: [String] = []
        if hasText { parts.append(text) }
        if imageCount > 0 { parts.append("[📎 \(imageCount) 张图片已附加]") }
        if !fileNames.isEmpty { parts.append(fileNames.map { "[📄 \($0)]" }.joined(separator: " ")) }
        return parts.joined(separator: "\n")
    }

    /// 附件正文注入段（现状 textFileContents 逐字）：
    /// 有落盘路径 → 拉模式（只给路径 + read_file 指令）；无路径 → 全额注入退化。
    public static func injectionSections(files: [PendingAttachment]) -> [String] {
        files.compactMap { f in
            if let path = f.savedPath, !path.isEmpty {
                return "[📄 \(f.name)]（原件已保存：\(path)）\n"
                    + "⛔ 该文件内容**未**随消息发送。如任务需要其内容，请用 read_file 读取上述绝对路径"
                    + "（docx/xlsx/pptx/pdf 会自动解析为文本+格式概要）；"
                    + "不要凭文件名臆测内容，读不到就如实说明。"
            }
            if let text = f.parsedText {
                return "[\(f.name)]（⚠️ 原件未能落盘，故全文随消息附上）\n\(text)"
            }
            return nil   // 解析失败且无路径：不注入（气泡上仍有文件名标注）
        }
    }

    /// 把注入段拼到最后一条消息正文（现状 finalMessages 注入点，ATTACH_MARK 分隔）。
    public static func appendInjection(toContent content: String, sections: [String]) -> String {
        guard !sections.isEmpty else { return content }
        return content + "\n\n" + ATTACH_MARK + "\n" + sections.joined(separator: "\n\n")
    }
}

// MARK: - segment_break（#1 0.4.20 插入点分裂）

public enum SegmentBreakLogic {
    /// done.content 是全文（loop.py full_text 跨轮累加 = 段1+段2）；
    /// 分裂后当前气泡是段2，只取 [break_at:]，否则段2 重复段1。
    public static func doneContent(full: String, breakAt: Int) -> String {
        guard breakAt >= 0, breakAt <= full.count else { return full }
        let idx = full.index(full.startIndex, offsetBy: breakAt)
        return String(full[idx...])
    }
}

// MARK: - 模型降级 / 视觉引导判定（M5 TS-111 / M6 TS-112）

public enum RescueRules {
    /// 「模型不存在」类错误判定（现状正则 /不存在|does not exist|not found|404/i）。
    public static func isModelMissingError(_ text: String) -> Bool {
        (try? NSRegularExpression(pattern: "不存在|does not exist|not found|404",
                                  options: [.caseInsensitive]))
            .map { $0.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil }
            ?? false
    }

    /// 视觉降级引导触发文案（现状 includes('[⚠️ 当前模型不支持多模态')）。
    public static let visionDegradedMark = "[⚠️ 当前模型不支持多模态"

    /// 视觉候选模型（现状 /vl|vision/i）。
    public static func isVisionModel(_ name: String) -> Bool {
        (try? NSRegularExpression(pattern: "vl|vision", options: [.caseInsensitive]))
            .map { $0.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil }
            ?? false
    }
}

// MARK: - 重连退避（M5 TS-111）

public enum ReconnectPolicy {
    /// 业务错误（400/404/422）立即终止不重试；网络/5xx/流中断走重连。
    public static func isBusinessError(_ error: Error) -> Bool {
        if case SidecarError.httpError(let status, _) = error {
            return status == 400 || status == 404 || status == 422
        }
        return false
    }

    /// 指数退避：1s→2s→4s… 上限 30s + 0~300ms jitter（现状逐字）。
    public static func backoffNanos(attempt: Int) -> UInt64 {
        let base = min(30000.0, 1000.0 * pow(2.0, Double(attempt - 1)))
        let jitter = Double(Int.random(in: 0...300))
        return UInt64((base + jitter) * 1_000_000)
    }

    /// 重连提示条文案（现状逐字）。
    public static func notice(attempt: Int, maxAttempts: Int) -> String {
        let base = min(30000.0, 1000.0 * pow(2.0, Double(attempt - 1)))
        return "正在恢复连接…（第 \(attempt)/\(maxAttempts) 次，\(Int((base / 1000).rounded()))s 后重试）"
    }

    /// 重试耗尽后的气泡错误文案（现状逐字）。
    public static func exhaustedMessage(attempt: Int, detail: String) -> String {
        "连接中断，已重试 \(attempt) 次仍失败。已保留已生成内容：\(detail)"
    }
}

// MARK: - DB/本地合并（0.7.8 实测 Bug1：checkpoint-055/H16/C8 mergeDbWithLocal 移植）

/// 会话消息加载收口唯一判据：DB 为权威源 + 合并「本地未落盘的流式气泡（local_ 前缀 id）」。
/// 逐字移植旧线 ChatPanel.tsx mergeDbWithLocal（L776-839，DBG-089 H16 + checkpoint-055）：
///   · local_ 气泡内容与 DB 同角色定稿**精确/前缀**匹配 → 跳过（C8 根因①：前端 abort
///     比后端少收几个 token 时，缓存 content 是 DB 定稿的前缀而非全等，精确匹配失配
///     会把副本当新消息追加到末尾且重复）；
///   · 正文为空的定稿按「工具步骤签名」去重，签名归一 running 视同 interrupted
///     （C8 补漏 0.4.17：只调工具没吐正文时点停止，content 空串会短路正文判据）；
///   · live=true（该会话仍有进行中的流）→ 原样保留，流会继续推进（H16 语义）；
///   · live=false 僵尸清理：空内容且无工具步骤 → 丢弃；有内容的 → 清活态标记
///     （思考中/等待秒数）+ isStreaming=false + running 步骤收敛 interrupted，
///     无 manualStopped 且无 completedDuration 的补 interruptedNote
///     「已中断执行（应用断开或崩溃，内容为半成品）」（不谎称用户手动停止）。
///
/// 【移植偏差记录】旧线僵尸恢复置 stopped=true；Swift UI 模型无 stopped 字段
///（DB stopped 列经 loadMessages 映射为 manuallyStopped，不能复用——不能谎称
/// 用户手动停止），以 isStreaming=false + convergeRunningSteps 承接其视觉收敛语义。
public func mergeDbWithLocal(db dbMsgs: [ChatMessage], local: [ChatMessage], live: Bool) -> [ChatMessage] {
    let dbIds = Set(dbMsgs.map { $0.id })
    let dbByContent = Set(dbMsgs.filter { !$0.content.isEmpty }.map { "\($0.role)::\($0.content)" })
    // C8：DB 同 role 定稿 content 列表，用于前缀匹配（精确匹配不够，见头注）
    var dbContentsByRole: [String: [String]] = [:]
    for m in dbMsgs where !m.content.isEmpty {
        dbContentsByRole[m.role, default: []].append(m.content)
    }
    func matchesDb(_ role: String, _ content: String) -> Bool {
        if content.isEmpty { return false }
        if dbByContent.contains("\(role)::\(content)") { return true }   // 精确
        // 前缀：DB 定稿比缓存长且以缓存为前缀
        return (dbContentsByRole[role] ?? []).contains { $0.count > content.count && $0.hasPrefix(content) }
    }
    // C8 补漏：空正文定稿按工具步骤签名去重；签名归一 running 视同 interrupted
    //（DB 定稿由 persistAssistant 收敛为 interrupted，缓存副本可能是收敛前的 running）
    func stepSig(_ steps: [ToolStep]) -> String {
        steps.map { "\($0.id)|\($0.name)|\($0.status == .running ? "interrupted" : $0.status.rawValue)" }
            .joined(separator: ";")
    }
    var dbEmptyBodySteps = Set<String>()
    for m in dbMsgs {
        guard m.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
        if !m.toolSteps.isEmpty { dbEmptyBodySteps.insert("\(m.role)::\(stepSig(m.toolSteps))") }
    }
    var extra: [ChatMessage] = []
    for m in local {
        let key = m.id
        if key.hasPrefix("local_") {
            // 流式气泡：DB 已有同角色、内容相同或以其为前缀的定稿 → 以 DB 为准不重复追加
            if !m.content.isEmpty && matchesDb(m.role, m.content) { continue }
            // 空正文改按工具步骤签名去重
            if m.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               !m.toolSteps.isEmpty,
               dbEmptyBodySteps.contains("\(m.role)::\(stepSig(m.toolSteps))") { continue }
            // 活流（该会话仍有进行中的流）→ 原样保留，流会继续推进
            if live { extra.append(m); continue }
            // checkpoint-059：僵尸清理——空内容（且无工具步骤）的进行态气泡不恢复
            //（后端要么已完成、要么已中断，均以 DB 为准）
            let hasSubstance = !m.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !m.toolSteps.isEmpty
            guard hasSubstance else { continue }
            // #13：有内容的中断气泡恢复时清活态标记；无 manualStopped 且无 completedDuration
            // → 异常中断的半成品，标「已中断执行」（不置 manualStopped，不谎称手动停止）
            var z = m
            z.thinkingActive = false
            z.waitingSeconds = 0
            z.isStreaming = false
            z.toolSteps = convergeRunningSteps(z.toolSteps)
            if !z.manuallyStopped && z.completedDuration == nil {
                z.interruptedNote = "已中断执行（应用断开或崩溃，内容为半成品）"
            }
            extra.append(z)
        } else if !key.isEmpty && !dbIds.contains(key) {
            extra.append(m)   // 本地 id 不在 DB（极端兜底）
        }
    }
    var merged = dbMsgs + extra
    // R1（0.7.12 实测 A5）：强退/崩溃后重进——末条停在 user 消息且无活流 ⇒
    // 该轮 assistant 从未落库（done 才落库，本地流式气泡随进程消失），
    // 用户面对「静默悬空」不知这条还算不算数。合成「已中断」标记气泡收尾
    // （local_ id 不落库；下次加载幂等重建），视图层挂「重新发送」出口
    // （回填该 user 消息进输入框，resendLast 语义复用，不发明新概念）。
    if !live, merged.last?.role == "user" {
        var marker = ChatMessage(id: LocalMessageID.next(), role: "assistant", content: "")
        marker.interruptedNote = "已中断执行（应用退出或崩溃，本轮未生成回复）"
        merged.append(marker)
    }
    return merged
}
