//
//  ChatPanelW1Tests.swift
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

//  会话面板移植逻辑单测：
//    · 输入归一化 / 时间格式化 / 上下文估算 / 归档扣减 / 工具步骤收敛
//    · Token 指示器文案（0.4.34 口径）/ 工具步骤组文案 / 附件组装（ATTACH_MARK 拉模式）
//    · segment_break 切段 / 模型降级判定 / 重连退避 / Markdown 块解析
//    · ViewModel 集成（mock ChatPanelClient + 脚本化 SSE 事件）：
//      工具步骤配对 / done 全文覆盖 / cancelled 收敛 / compact_required / 停止纪律②
//

import XCTest
@testable import VetarAINative

// MARK: - 输入归一化（B1 0.4.12）

final class ChatInputNormalizeTests: XCTestCase {

    func testZeroWidthStripped() {
        // 零宽/BOM/软连字符剔除（现状字符集逐字）
        XCTAssertEqual(normalizeInputText("a\u{200B}b\u{FEFF}c\u{00AD}"), "abc")
        XCTAssertEqual(normalizeInputText("x\u{200C}\u{200D}\u{2060}y"), "xy")
    }

    func testNBSPDowngradedToSpace() {
        // \u00A0 降级为普通空格（直接删会让两侧单词粘连）
        XCTAssertEqual(normalizeInputText("a\u{00A0}b"), "a b")
    }

    func testNewlinesAndSpacesPreserved() {
        // Shift+Enter 换行与词间空格是内容，不是噪音（B1 根因①回归守护）
        XCTAssertEqual(normalizeInputText("please fix\nthis bug"), "please fix\nthis bug")
        XCTAssertEqual(normalizeInputText("  缩进  "), "  缩进  ")
    }

    func testHasSendableText() {
        XCTAssertFalse(hasSendableText(""))
        XCTAssertFalse(hasSendableText("   \n\t  "))
        XCTAssertFalse(hasSendableText("\u{200B}\u{FEFF}"))   // 纯不可见字符 = 不可发送（死点击修复）
        XCTAssertTrue(hasSendableText("hi"))
        XCTAssertTrue(hasSendableText("  hi  "))
    }
}

// MARK: - 时间格式化（TS-116）

final class ChatFormatTimeTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)  // 固定参考时刻

    func testInvalidAndEmpty() {
        XCTAssertEqual(formatChatTime("", now: now), "")
        XCTAssertEqual(formatChatTime("not-a-date", now: now), "")
    }

    func testJustNowAndMinutes() {
        let f = ISO8601DateFormatter()
        XCTAssertEqual(formatChatTime(f.string(from: now.addingTimeInterval(-20)), now: now), "刚刚")
        XCTAssertEqual(formatChatTime(f.string(from: now.addingTimeInterval(-300)), now: now), "5 分钟前")
    }

    func testUTCStringWithoutT() {
        // SQLite datetime('now') 形如 "2027-01-15 10:00:00"（UTC，无 T 无 Z）→ 补 Z 解析
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
        fmt.timeZone = TimeZone(identifier: "UTC")
        let raw = fmt.string(from: now.addingTimeInterval(-120))
        XCTAssertEqual(formatChatTime(raw, now: now), "2 分钟前")
    }
}

// MARK: - 上下文估算与归档扣减（M2 / A/B-2 0.4.23）

final class ChatContextEstimateTests: XCTestCase {

    private func msg(_ role: String, _ content: String, archived: Bool = false, dbId: Int? = nil) -> ChatMessage {
        var m = ChatMessage(id: dbId.map(String.init) ?? UUID().uuidString, role: role, content: content)
        m.dbId = dbId
        m.archived = archived
        return m
    }

    func testBackendCharsTakePriority() {
        // B3：后端真实字数优先（0.6 系数换算）
        let msgs = [msg("user", "短")]
        XCTAssertEqual(estimateContextTokens(messages: msgs, backendCtxChars: 1000), 600)
    }

    func testHeuristicSkipsArchivedAndSystem() {
        let msgs = [
            msg("user", String(repeating: "a", count: 100)),          // 60
            msg("assistant", String(repeating: "b", count: 100)),     // 60
            msg("system", String(repeating: "c", count: 100)),        // 不计
            msg("user", String(repeating: "d", count: 100), archived: true),  // 已归档不计
        ]
        XCTAssertEqual(estimateContextTokens(messages: msgs, backendCtxChars: 0), 120)
    }

    func testArchiveDeductionNoBackendTruth() {
        // 无后端真值 → 不扣减（0, nil），交回启发式兜底
        let r = ctxTokensAfterArchive(backendCtxChars: 0,
                                      messages: [msg("user", "abc", dbId: 1)],
                                      archivedDbIds: [1])
        XCTAssertEqual(r.nextCtxChars, 0)
        XCTAssertNil(r.nextTokenUsed)
    }

    func testArchiveDeductionNormal() {
        let msgs = [msg("user", String(repeating: "a", count: 200), dbId: 1),
                    msg("assistant", String(repeating: "b", count: 300), dbId: 2)]
        let r = ctxTokensAfterArchive(backendCtxChars: 1000, messages: msgs, archivedDbIds: [2])
        XCTAssertEqual(r.nextCtxChars, 700)
        XCTAssertEqual(r.nextTokenUsed, 420)   // round(700 * 0.6)
    }

    func testArchiveDeductionToZeroYieldsNil() {
        // 扣到 0 → nil（不硬显示 0，交回估算）
        let msgs = [msg("user", String(repeating: "a", count: 500), dbId: 1)]
        let r = ctxTokensAfterArchive(backendCtxChars: 500, messages: msgs, archivedDbIds: [1])
        XCTAssertEqual(r.nextCtxChars, 0)
        XCTAssertNil(r.nextTokenUsed)
    }
}

// MARK: - 工具步骤收敛与文案（C2/C8/checkpoint-060）

final class ToolStepsLogicTests: XCTestCase {

    func testConvergeRunningToInterrupted() {
        let steps = [
            ToolStep(id: "1", name: "read_file", status: .ok),
            ToolStep(id: "2", name: "fs_write", status: .running),
        ]
        let out = convergeRunningSteps(steps)
        XCTAssertEqual(out[0].status, .ok)
        XCTAssertEqual(out[1].status, .interrupted)
    }

    func testConvergeNoRunningIsIdentity() {
        let steps = [ToolStep(id: "1", name: "t", status: .ok)]
        XCTAssertEqual(convergeRunningSteps(steps), steps)
    }

    func testStepLabels() {
        // 现状 ToolStepBar label 逐字
        XCTAssertEqual(ToolStepsCopy.stepLabel(ToolStep(id: "1", name: "read_file", status: .running)),
                       "正在调用 read_file…")
        XCTAssertEqual(ToolStepsCopy.stepLabel(ToolStep(id: "1", name: "read_file", status: .interrupted)),
                       "read_file（已中断，未完成）")
        XCTAssertEqual(ToolStepsCopy.stepLabel(ToolStep(id: "1", name: "read_file", status: .ok, summary: "3 行")),
                       "read_file 完成（3 行）")
        XCTAssertEqual(ToolStepsCopy.stepLabel(ToolStep(id: "1", name: "read_file", status: .ok)),
                       "read_file 完成（ok）")
        XCTAssertEqual(ToolStepsCopy.stepLabel(ToolStep(id: "1", name: "fs_write", status: .error, error: "denied")),
                       "fs_write 失败：denied")
        XCTAssertEqual(ToolStepsCopy.stepLabel(ToolStep(id: "1", name: "fs_write", status: .error)),
                       "fs_write 失败：unknown")
    }

    func testGroupLabels() {
        let ok = ToolStep(id: "1", name: "a", status: .ok)
        let err = ToolStep(id: "2", name: "b", status: .error)
        let int_ = ToolStep(id: "3", name: "c", status: .interrupted)
        let run = ToolStep(id: "4", name: "d", status: .running)

        XCTAssertEqual(ToolStepsCopy.groupLabel(steps: [ok], collapsed: true),
                       "工具调用 1 步 · 已完成")
        XCTAssertEqual(ToolStepsCopy.groupLabel(steps: [ok, err], collapsed: true),
                       "工具调用 2 步 · 1 成功 · 1 失败")
        XCTAssertEqual(ToolStepsCopy.groupLabel(steps: [ok, err, int_], collapsed: true),
                       "工具调用 3 步 · 1 成功 · 1 失败 · 1 中断")
        XCTAssertEqual(ToolStepsCopy.groupLabel(steps: [ok, int_], collapsed: true),
                       "工具调用 2 步 · 1 成功 · 1 中断")
        XCTAssertEqual(ToolStepsCopy.groupLabel(steps: [ok, run], collapsed: false),
                       "正在调用工具（1/2 进行中）…")
        XCTAssertEqual(ToolStepsCopy.groupLabel(steps: [ok, err], collapsed: false),
                       "工具调用 2 步")
    }

    func testShouldCollapse() {
        // 现状 shouldCollapse = done && running === 0
        let run = ToolStep(id: "1", name: "a", status: .running)
        let ok = ToolStep(id: "2", name: "b", status: .ok)
        XCTAssertFalse(ToolStepsCopy.shouldCollapse(steps: [run, ok], streamDone: true))
        XCTAssertFalse(ToolStepsCopy.shouldCollapse(steps: [ok], streamDone: false))
        XCTAssertTrue(ToolStepsCopy.shouldCollapse(steps: [ok], streamDone: true))
        // C8：interrupted 不算 running（用户停止后步骤组可收拢）
        XCTAssertTrue(ToolStepsCopy.shouldCollapse(
            steps: [ToolStep(id: "3", name: "c", status: .interrupted)], streamDone: true))
    }
}

// MARK: - Token 指示器（R3 0.4.33 / 0.4.31 D4）

final class TokenIndicatorTests: XCTestCase {

    func testSingleValueDisplay() {
        var s = TokenIndicatorState()
        s.used = 120; s.limit = 1000; s.ceiling = 0
        XCTAssertEqual(s.displayText, "上下文 ≈120 / 1,000")
        XCTAssertEqual(s.divisor, 1000)
        XCTAssertEqual(s.tooltip,
                       "当前会话上下文估算：约 120 / 上限 1,000（按未移入仓库的对话实时估算，移入仓库后即下降；非模型精确计费口径）")
    }

    func testLazyCeilingDisplay() {
        // 0.4.34：懒加载生效 → 主数字 = 上限，「当前档 N」进括号
        var s = TokenIndicatorState()
        s.used = 9000; s.limit = 12288; s.ceiling = 131072
        XCTAssertEqual(s.displayText, "上下文 ≈9,000 / 131,072（当前档 12,288）")
        XCTAssertEqual(s.divisor, 131072)
        XCTAssertEqual(s.tooltip,
                       "当前会话上下文估算：约 9,000 / 上限 131,072（懒加载：当前档 12,288，上下文膨胀自动升档直至上限；按未移入仓库的对话实时估算，非模型精确计费口径）")
    }

    func testBarLevels() {
        var s = TokenIndicatorState()
        s.limit = 100
        s.used = 50;  XCTAssertEqual(s.barLevel, .ok)
        s.used = 90;  XCTAssertEqual(s.barLevel, .warn)
        s.used = 99;  XCTAssertEqual(s.barLevel, .danger)
    }

    func testFailedText() {
        var s = TokenIndicatorState()
        s.limit = 0; s.source = "error"
        XCTAssertEqual(s.failedText, "上下文：获取失败")
        s.source = "config"
        XCTAssertNil(s.failedText)
    }
}

// MARK: - 附件组装（checkpoint-048 / 表#6 拉模式）

final class AttachmentComposerTests: XCTestCase {

    private func file(_ name: String, parsed: String? = nil, path: String? = nil) -> PendingAttachment {
        var f = PendingAttachment(name: name, kind: .file, size: 10, dataURI: "data:x;base64,AA==")
        f.parsedText = parsed
        f.savedPath = path
        return f
    }

    func testUserBubbleText() {
        // 现状 parts 逐字
        XCTAssertEqual(AttachmentComposer.userBubbleText(text: "看一下", hasText: true,
                                                         imageCount: 2, fileNames: ["a.pdf"]),
                       "看一下\n[📎 2 张图片已附加]\n[📄 a.pdf]")
        XCTAssertEqual(AttachmentComposer.userBubbleText(text: "", hasText: false,
                                                         imageCount: 0, fileNames: ["a.txt", "b.txt"]),
                       "[📄 a.txt] [📄 b.txt]")
    }

    func testInjectionPullMode() {
        // 有落盘路径 → 只给路径 + read_file 指令（逐字）
        let sections = AttachmentComposer.injectionSections(files: [file("合同.docx", path: "/tmp/x/合同.docx")])
        XCTAssertEqual(sections.count, 1)
        XCTAssertEqual(sections[0],
                       "[📄 合同.docx]（原件已保存：/tmp/x/合同.docx）\n"
                       + "⛔ 该文件内容**未**随消息发送。如任务需要其内容，请用 read_file 读取上述绝对路径"
                       + "（docx/xlsx/pptx/pdf 会自动解析为文本+格式概要）；"
                       + "不要凭文件名臆测内容，读不到就如实说明。")
    }

    func testInjectionFallbackFullText() {
        // 无路径 → 全额注入（宁多占上下文，不可让 agent 彻底看不到文件）
        let sections = AttachmentComposer.injectionSections(files: [file("note.txt", parsed: "正文内容")])
        XCTAssertEqual(sections, ["[note.txt]（⚠️ 原件未能落盘，故全文随消息附上）\n正文内容"])
    }

    func testInjectionDropsUnparsedWithoutPath() {
        XCTAssertEqual(AttachmentComposer.injectionSections(files: [file("x.zip")]), [])
    }

    func testAttachMarkInjection() {
        let out = AttachmentComposer.appendInjection(toContent: "分析这个", sections: ["S1", "S2"])
        XCTAssertEqual(out, "分析这个\n\n\(ATTACH_MARK)\nS1\n\nS2")
        XCTAssertEqual(AttachmentComposer.appendInjection(toContent: "hi", sections: []), "hi")
        XCTAssertEqual(ATTACH_MARK, "--- 附件内容 ---")
    }
}

// MARK: - segment_break / 重连 / 降级判定

final class ChatStreamLogicTests: XCTestCase {

    func testDoneContentSlicing() {
        // #1：done.content 是全文；分裂后段2 只取 [break_at:]
        XCTAssertEqual(SegmentBreakLogic.doneContent(full: "段一内容段二内容", breakAt: 4), "段二内容")
        XCTAssertEqual(SegmentBreakLogic.doneContent(full: "完整", breakAt: -1), "完整")
        XCTAssertEqual(SegmentBreakLogic.doneContent(full: "短", breakAt: 99), "短")   // 越界防御
    }

    func testBusinessErrorClassification() {
        XCTAssertTrue(ReconnectPolicy.isBusinessError(SidecarError.httpError(status: 400, detail: "")))
        XCTAssertTrue(ReconnectPolicy.isBusinessError(SidecarError.httpError(status: 404, detail: "")))
        XCTAssertTrue(ReconnectPolicy.isBusinessError(SidecarError.httpError(status: 422, detail: "")))
        XCTAssertFalse(ReconnectPolicy.isBusinessError(SidecarError.httpError(status: 500, detail: "")))
        XCTAssertFalse(ReconnectPolicy.isBusinessError(SidecarError.timeout))
    }

    func testBackoffSeries() {
        // 1s→2s→4s… 上限 30s + jitter ≤300ms
        let b1 = ReconnectPolicy.backoffNanos(attempt: 1)
        XCTAssertGreaterThanOrEqual(b1, 1_000_000_000)
        XCTAssertLessThanOrEqual(b1, 1_300_000_000)
        let b3 = ReconnectPolicy.backoffNanos(attempt: 3)
        XCTAssertGreaterThanOrEqual(b3, 4_000_000_000)
        XCTAssertLessThanOrEqual(b3, 4_300_000_000)
        let b99 = ReconnectPolicy.backoffNanos(attempt: 99)
        XCTAssertLessThanOrEqual(b99, 30_300_000_000)
    }

    func testReconnectNoticeCopy() {
        XCTAssertEqual(ReconnectPolicy.notice(attempt: 2, maxAttempts: 3),
                       "正在恢复连接…（第 2/3 次，2s 后重试）")
        XCTAssertEqual(ReconnectPolicy.exhaustedMessage(attempt: 3, detail: "超时"),
                       "连接中断，已重试 3 次仍失败。已保留已生成内容：超时")
    }

    func testModelMissingRule() {
        XCTAssertTrue(RescueRules.isModelMissingError("模型 qwen 不存在"))
        XCTAssertTrue(RescueRules.isModelMissingError("model does not exist"))
        XCTAssertTrue(RescueRules.isModelMissingError("HTTP 404: not found"))
        XCTAssertFalse(RescueRules.isModelMissingError("超时"))
    }

    func testVisionRules() {
        XCTAssertTrue(RescueRules.isVisionModel("qwen2.5-vl"))
        XCTAssertTrue(RescueRules.isVisionModel("LLaVA-Vision-7B"))
        XCTAssertFalse(RescueRules.isVisionModel("qwen3.8"))
        XCTAssertEqual(RescueRules.visionDegradedMark, "[⚠️ 当前模型不支持多模态")
    }

    func testThinkingPreviewTail() {
        let long = String(repeating: "思", count: 200)
        XCTAssertEqual(appendThinkingPreview("", delta: long).count, 120)
        XCTAssertEqual(appendThinkingPreview("旧", delta: "新"), "旧新")
    }
}

// MARK: - Markdown 块解析

final class MarkdownBlocksTests: XCTestCase {

    func testFencesBalanced() {
        XCTAssertTrue(MarkdownBlocks.fencesBalanced("无围栏"))
        XCTAssertTrue(MarkdownBlocks.fencesBalanced("```\ncode\n```"))
        XCTAssertFalse(MarkdownBlocks.fencesBalanced("```\n未闭合"))
        XCTAssertFalse(MarkdownBlocks.fencesBalanced("```a```\n```"))   // 3 个 = 奇数
    }

    func testParseBlocks() {
        let md = """
        # 标题
        第一段 **粗体**。

        ```swift
        let x = 1
        ```

        - 甲
        - 乙

        1. 一
        2. 二

        > 引用行

        | 列A | 列B |
        | --- | --- |
        | 1 | 2 |

        ---
        收尾
        """
        let blocks = MarkdownBlocks.parse(md)
        XCTAssertEqual(blocks[0], .heading(level: 1, text: "标题"))
        XCTAssertTrue(blocks.contains(.paragraph("第一段 **粗体**。")))
        XCTAssertTrue(blocks.contains(.code(lang: "swift", code: "let x = 1")))
        XCTAssertTrue(blocks.contains(.list(ordered: false, items: ["甲", "乙"])))
        XCTAssertTrue(blocks.contains(.list(ordered: true, items: ["一", "二"])))
        XCTAssertTrue(blocks.contains(.quote("引用行")))
        XCTAssertTrue(blocks.contains(.table(rows: [["列A", "列B"], ["1", "2"]])))
        XCTAssertTrue(blocks.contains(.hr))
        XCTAssertTrue(blocks.contains(.paragraph("收尾")))
    }

    func testParseKeepsCodeFencesOutOfParagraphs() {
        let blocks = MarkdownBlocks.parse("前文\n```\nlet a=1\n```\n后文")
        XCTAssertEqual(blocks.count, 3)
        XCTAssertEqual(blocks[1], .code(lang: "", code: "let a=1"))
    }
}

// MARK: - 请求编码

final class ChatRequestEncodingTests: XCTestCase {

    func testStreamRequestKeys() throws {
        let req = ChatStreamRequest(agent_id: "a1", model: "qwen3.8",
                                    messages: [ChatStreamMessage(role: "user", content: "hi")],
                                    images: ["data:image/png;base64,AA=="],
                                    project_id: "p1", session_id: "s1",
                                    skip_user_persist: true, sandbox_root: "/tmp/sb",
                                    auto_archive_unit: true)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(req)) as? [String: Any])
        XCTAssertEqual(obj["agent_id"] as? String, "a1")
        XCTAssertEqual(obj["skip_user_persist"] as? Bool, true)
        XCTAssertEqual(obj["auto_archive_unit"] as? Bool, true)
        XCTAssertEqual((obj["images"] as? [String])?.count, 1)
        XCTAssertEqual(obj["sandbox_root"] as? String, "/tmp/sb")
    }

    func testKnowledgeTransferEncoding() throws {
        let req = KnowledgeTransferRequest(projectId: "p1", sessionId: "s1", messageIds: [3, 5],
                                           scope: "global", title: nil, category: "", keywords: ["a"])
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(req)) as? [String: Any])
        XCTAssertEqual(obj["message_ids"] as? [Int], [3, 5])
        XCTAssertEqual(obj["scope"] as? String, "global")
        XCTAssertNil(obj["title"])   // nil 省略（后端自动取首条前 20 字）
    }
}

// MARK: - ViewModel 集成（脚本化 SSE 事件）

/// 会话面板 mock 客户端（实现 ChatPanelClient 全协议；chatStream 播脚本事件）。
@MainActor
final class ChatMockClient: ChatPanelClient {
    let baseURL = URL(string: "http://127.0.0.1:1/api")!
    var streamEvents: [SSEEvent] = []
    var streamError: Error?
    var streamNeverEnds = false
    private(set) var stoppedSessions: [String] = []
    private(set) var injected: [String] = []
    var dbMessages: [ChatMessage] = []
    var contextLimit = ContextLimitInfo(limit: 1000, source: "config")
    var config: [String: Any] = [:]
    /// 0.7.8 Bug3 钉桩用：记录最近一次 chatStream 入参（断言 sandbox_root 口径）。
    private(set) var lastStreamRequest: ChatStreamRequest?
    /// 0.7.8 Bug1 钉桩用：neverEnds 流的 continuation 持有——测试可中途补事件/收尾
    ///（模拟「切走后后台流仍在推进，切回后流 done」的完整生命周期）。
    private(set) var streamContinuation: AsyncThrowingStream<SSEEvent, Error>.Continuation?
    func pushStreamEvent(_ ev: SSEEvent) { streamContinuation?.yield(ev) }
    func finishStream() { streamContinuation?.finish() }

    func probeReady() async throws -> Bool { true }
    /// 可配置模型列表（默认沿用历史单模型值；0.7.10 ModelIdentity 测试覆盖归一化场景）
    var modelList: [OllamaModel] = [OllamaModel(name: "qwen3.8", size: nil)]
    func listModels() async throws -> [OllamaModel] { modelList }
    func listProjects() async throws -> [SidecarProject] { [] }
    func createProject(name: String, workingDir: String) async throws -> String { "p1" }
    func listAgents(projectId: String) async throws -> [SidecarAgent] { [] }
    func createAgent(projectId: String, name: String, type: String, modelName: String?) async throws -> String { "a1" }
    func listSessions(projectId: String, agentId: String) async throws -> [ChatSession] {
        // 0.7.8 Bug1 测试：会话列表按项目归属（p1 之外返回空，模拟切换到别的上下文）
        guard projectId == "p1" else { return [] }
        return [ChatSession(id: "s1", title: "会话 1", message_count: 0)]
    }
    func createSession(projectId: String, agentId: String, title: String) async throws -> String {
        projectId == "p1" ? "s1" : "s-\(projectId)"
    }
    func loadMessages(projectId: String, sessionId: String) async throws -> [ChatMessage] { dbMessages }
    func stopChat(sessionId: String) async throws { stoppedSessions.append(sessionId) }
    func respondAuth(_ body: AuthRespondRequest) async throws {}

    func chatStream(_ body: ChatStreamRequest) -> AsyncThrowingStream<SSEEvent, Error> {
        lastStreamRequest = body
        let events = streamEvents
        let error = streamError
        let neverEnds = streamNeverEnds
        return AsyncThrowingStream { cont in
            for ev in events { cont.yield(ev) }
            if let error { cont.finish(throwing: error); return }
            if neverEnds {
                streamContinuation = cont   // Bug1 测试：持有续流口（可中途 pushStreamEvent）
                cont.onTermination = { _ in }
                return   // 不 finish：模拟进行中的流（停止测试用）
            }
            cont.finish()
        }
    }

    func fetchConfig() async throws -> [String: Any] { config }
    func fetchContextLimit(model: String) async throws -> ContextLimitInfo { contextLimit }
    func renameSession(projectId: String, sessionId: String, title: String) async throws {}
    func deleteSession(projectId: String, sessionId: String) async throws -> Bool { true }
    func compactSession(projectId: String, sessionId: String) async throws {}
    func exportSession(projectId: String, agentId: String, sessionId: String, dir: String?) async throws -> ExportResult {
        var r = ExportResult(); r.ok = true; r.name = "会话.md"; return r
    }
    func summarizeSession(projectId: String, agentId: String, sessionId: String, model: String) async throws -> SummarizeResult {
        var r = SummarizeResult(); r.ok = true; r.savedFile = "/tmp/x/summary.md"; return r
    }
    func parseAttachment(name: String, contentBase64: String, projectId: String,
                         sessionId: String) async throws -> AttachmentParseResult {
        var r = AttachmentParseResult(); r.name = name; r.text = "解析文本"
        r.savedPath = "/tmp/att/\(name)"; return r
    }
    func injectMessage(projectId: String, agentId: String, sessionId: String,
                       content: String) async throws -> InjectResult {
        injected.append(content)
        return InjectResult(ok: true, detail: nil)
    }
    func updateAgentModel(projectId: String, agentId: String, modelName: String) async throws {}
    func pullModel(name: String) async throws {}
    func fetchInferenceBackend() async throws -> String { "ollama" }
    func transferToWarehouse(_ req: KnowledgeTransferRequest) async throws -> KnowledgeTransferResult {
        var r = KnowledgeTransferResult(); r.ok = true; r.title = "条目"; r.archived = req.message_ids.count
        return r
    }
}

@MainActor
final class ChatViewModelIntegrationTests: XCTestCase {

    private func bootstrappedVM(_ client: ChatMockClient) async throws -> ChatViewModel {
        let appState = TestRuntimeSupport.makeAppState(client: client)
        // 0.7.6 实测 Bug1 新口径：无 pilot 播种——上下文 = 用户选中态，测试显式预置
        appState.currentProjectId = "p1"
        appState.currentAgentId = "a1"
        let vm = ChatViewModel(appState: appState)
        // runtime init 同步点亮 nativeReady → sink 立即触发 bootstrap，稍候即完成
        try await Task.sleep(nanoseconds: 800_000_000)
        XCTAssertTrue(vm.bootstrapped, "bootstrap 未完成")
        XCTAssertEqual(vm.currentSessionId, "s1")
        return vm
    }

    private func ev(_ event: String, _ data: [String: Any] = [:]) -> SSEEvent {
        SSEEvent(event: event, data: data, rawData: "")
    }

    /// F6（0.7.12 实测 A8）：模型下拉换 Menu 自定义行的数据层保证——
    /// 选择模型绝不回排 vm.models（旧原生 NSPopUpButton 选中项对齐即「置顶重排」，
    /// Menu 行序恒 = vm.models 序，顺序稳定由本不变量兜底）。
    func testModelListOrderStableAcrossSelectionChange() async throws {
        let client = ChatMockClient()
        client.modelList = [OllamaModel(name: "qwen3-vl:8b", size: nil),
                            OllamaModel(name: "deepseek-r1:14b", size: nil),
                            OllamaModel(name: "qwen3.8", size: nil)]
        let vm = try await bootstrappedVM(client)
        let before = vm.models.map(\.name)
        XCTAssertEqual(before, ["qwen3-vl:8b", "deepseek-r1:14b", "qwen3.8"])

        vm.selectedModel = "qwen3.8"
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(vm.models.map(\.name), before, "选中末位模型后名单顺序不得变")
        vm.selectedModel = "qwen3-vl:8b"
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(vm.models.map(\.name), before, "来回切换后名单顺序不得变")
    }

    // 0.7.8 实测 Bug3：send 不再硬编码 <数据根>/pilot-sandbox——前端传 nil，
    // sandbox_root 交端点 _resolve_sandbox_root 按 project_id+agent_id 解析
    //（项目 → projects.working_dir；旧 Electron 线前端本就不传该字段）。
    func testSendLeavesSandboxRootToEndpointResolution() async throws {
        let client = ChatMockClient()
        let vm = try await bootstrappedVM(client)
        vm.input = "hi"
        vm.send()
        try await Task.sleep(nanoseconds: 300_000_000)
        let req = try XCTUnwrap(client.lastStreamRequest, "send 必须发出 chatStream 请求")
        XCTAssertNil(req.sandbox_root,
                     "Bug3：前端不得再硬编码 pilot-sandbox（敏感域内，写入必触发授权）")
        XCTAssertEqual(req.project_id, "p1")
        XCTAssertEqual(req.agent_id, "a1")
        XCTAssertEqual(req.session_id, "s1")
    }

    // 完整一轮：token 合帧落地 + 工具步骤配对 + state 计数 + done 全文覆盖
    func testFullRoundWithToolCall() async throws {
        let client = ChatMockClient()
        client.streamEvents = [
            ev("thinking", ["delta": "先想想"]),
            ev("tool_call", ["id": "t1", "name": "read_file", "args": ["path": "/tmp/a.txt"]]),
            ev("tool_result", ["id": "t1", "ok": true, "summary": "3 行"]),
            ev("state", ["step": 1, "max": 200, "tokens_used": 321, "ctx_chars": 500]),
            ev("token", ["delta": "读完了"]),
            ev("done", ["content": "读完了，文件有 3 行。"]),
        ]
        client.dbMessages = []
        let vm = try await bootstrappedVM(client)
        vm.input = "读一下 a.txt"
        vm.send()
        try await Task.sleep(nanoseconds: 500_000_000)

        let assistant = vm.messages.last(where: { $0.role == "assistant" })
        XCTAssertNotNil(assistant)
        // done.content 全文覆盖口径
        XCTAssertEqual(assistant?.content, "读完了，文件有 3 行。")
        // 工具步骤配对（tool_call/tool_result）
        XCTAssertEqual(assistant?.toolSteps.count, 1)
        XCTAssertEqual(assistant?.toolSteps.first?.status, .ok)
        XCTAssertEqual(assistant?.toolSteps.first?.summary, "3 行")
        XCTAssertNotNil(assistant?.toolSteps.first?.argsText)
        // state 计数
        XCTAssertEqual(assistant?.step, 1)
        XCTAssertEqual(assistant?.maxStep, 200)
        XCTAssertEqual(assistant?.tokensUsed, 321)
        // B3：ctx_chars 驱动指示器（500 × 0.6 = 300）
        XCTAssertEqual(vm.tokenIndicator.used, 300)
        // 思考预览已落地且阶段已关闭
        XCTAssertEqual(assistant?.thinkingPreview, "先想想")
        XCTAssertEqual(assistant?.thinkingActive, false)
        XCTAssertFalse(vm.sending)
        // R3：done 后重拉 /context/limit（mock 恒返回 1000/config）
        XCTAssertEqual(vm.tokenIndicator.limit, 1000)
    }

    // 纪律②：停止 = 先 POST stop 再断本地流；气泡收敛 manualStopped + running→interrupted
    func testStopConvergesAndPostsBackend() async throws {
        let client = ChatMockClient()
        client.streamNeverEnds = true
        client.streamEvents = [
            ev("tool_call", ["id": "t1", "name": "shell", "args": [:]]),
            ev("token", ["delta": "部分"]),
        ]
        let vm = try await bootstrappedVM(client)
        vm.input = "跑个长任务"
        vm.send()
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(vm.sending)

        vm.stop()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(client.stoppedSessions, ["s1"])   // POST /chat/s1/stop 已发
        XCTAssertFalse(vm.sending)
        let assistant = vm.messages.last(where: { $0.role == "assistant" })
        XCTAssertEqual(assistant?.manuallyStopped, true)
        XCTAssertEqual(assistant?.toolSteps.first?.status, .interrupted)   // C2 根因③收敛
        XCTAssertTrue(assistant?.content.contains("部分") ?? false)
    }

    // cancelled 事件 = 后端确认停止，语义同手动停止
    func testCancelledEventConverges() async throws {
        let client = ChatMockClient()
        client.streamEvents = [
            ev("tool_call", ["id": "t1", "name": "shell", "args": [:]]),
            ev("cancelled"),
        ]
        let vm = try await bootstrappedVM(client)
        vm.input = "hi"
        vm.send()
        try await Task.sleep(nanoseconds: 400_000_000)
        let assistant = vm.messages.last(where: { $0.role == "assistant" })
        XCTAssertEqual(assistant?.manuallyStopped, true)
        XCTAssertEqual(assistant?.toolSteps.first?.status, .interrupted)
        XCTAssertFalse(vm.sending)
    }

    // compact_required：警告条 + 输入禁用（现状 inputDisabled 口径）
    func testCompactRequiredShowsWarning() async throws {
        let client = ChatMockClient()
        client.streamEvents = [
            ev("compact_required", ["used": 950, "limit": 1000, "est_rounds_left": 2]),
        ]
        let vm = try await bootstrappedVM(client)
        vm.input = "hi"
        vm.send()
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(vm.compactWarning?.used, 950)
        XCTAssertEqual(vm.compactWarning?.limit, 1000)
        XCTAssertEqual(vm.compactWarning?.est, 2)
        XCTAssertTrue(vm.inputDisabled)
        XCTAssertFalse(vm.sending)
    }

    // segment_break：段1 定格 + 段2 重指向 + done 只取 [break_at:]
    func testSegmentBreakSplitsBubbles() async throws {
        let client = ChatMockClient()
        client.streamEvents = [
            ev("token", ["delta": "段一"]),
            ev("segment_break", ["break_at": 2, "injected_messages": [["content": "插入的话"]]]),
            ev("token", ["delta": "段二"]),
            ev("done", ["content": "段一段二"]),
        ]
        let vm = try await bootstrappedVM(client)
        vm.input = "hi"
        vm.send()
        try await Task.sleep(nanoseconds: 500_000_000)

        let assistants = vm.messages.filter { $0.role == "assistant" }
        XCTAssertEqual(assistants.count, 2)
        XCTAssertEqual(assistants[0].content, "段一")
        XCTAssertNotNil(assistants[0].completedDuration)   // 段1 定格必带完成用时
        XCTAssertEqual(assistants[1].content, "段二")       // break_at 切段，不重复段1
        // 注入的用户气泡落在段1 与段2 之间
        let roles = vm.messages.map { $0.role }
        let injIdx = vm.messages.firstIndex(where: { $0.content == "插入的话" })
        XCTAssertNotNil(injIdx)
        if let injIdx {
            XCTAssertEqual(roles[injIdx], "user")
            XCTAssertTrue(injIdx > vm.messages.firstIndex(where: { $0.id == assistants[0].id })!)
        }
    }

    // state 事件 ctx_chars 单调守门（checkpoint-109）：旧值晚到不覆盖
    func testCtxCharsMonotonicGuard() async throws {
        let client = ChatMockClient()
        client.streamEvents = [
            ev("state", ["step": 1, "ctx_chars": 1000]),
            ev("state", ["step": 2, "ctx_chars": 600]),   // 重连旧值晚到 → 被守门夹住
            ev("done", ["content": "完"]),
        ]
        let vm = try await bootstrappedVM(client)
        vm.input = "hi"
        vm.send()
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(vm.backendCtxChars, 1000)
        XCTAssertEqual(vm.tokenIndicator.used, 600)   // round(1000*0.6)，不回落
    }

    // error 事件：报错 + 分析字段
    func testErrorEventWithAnalysis() async throws {
        let client = ChatMockClient()
        client.streamEvents = [
            ev("error", ["detail": "模型不存在", "analysis": "该模型未拉取", "analysis_model": "qwen3.8"]),
        ]
        let vm = try await bootstrappedVM(client)
        vm.input = "hi"
        vm.send()
        try await Task.sleep(nanoseconds: 400_000_000)
        let assistant = vm.messages.last(where: { $0.role == "assistant" })
        XCTAssertEqual(assistant?.streamError, "模型不存在")
        XCTAssertEqual(assistant?.errorAnalysis, "该模型未拉取")
        XCTAssertEqual(assistant?.errorAnalysisModel, "qwen3.8")
        XCTAssertFalse(vm.sending)
    }

    // auth_request → 全局授权中心呈递（Wave 0 链路接入验证）
    func testAuthRequestRoutedToAuthCenter() async throws {
        let client = ChatMockClient()
        client.streamEvents = [
            ev("auth_request", ["request_id": "r1", "action": "delete",
                                "tool_name": "fs_delete", "target_path": "/tmp/x"]),
            ev("done", ["content": "完"]),
        ]
        let vm = try await bootstrappedVM(client)
        vm.input = "删一下"
        vm.send()
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertNotNil(vm.appState.auth.pending)
        XCTAssertEqual(vm.appState.auth.pending?.id, "r1")
    }

    // 业务错误（400）不重试；网络错误重试到上限（M5 分类）
    func testBusinessErrorNoRetry() async throws {
        let client = ChatMockClient()
        client.streamError = SidecarError.httpError(status: 404, detail: "model does not exist")
        let vm = try await bootstrappedVM(client)
        vm.input = "hi"
        vm.send()
        try await Task.sleep(nanoseconds: 400_000_000)
        let assistant = vm.messages.last(where: { $0.role == "assistant" })
        XCTAssertEqual(assistant?.errorKind, "business")
        XCTAssertNil(vm.reconnectNotice)
        XCTAssertFalse(vm.sending)
    }

    // A5：思考中发送 → 走注入（POST /chat/{sid}/inject），不打断当前轮
    func testInjectWhileSending() async throws {
        let client = ChatMockClient()
        client.streamNeverEnds = true
        client.streamEvents = [ev("thinking", ["delta": "…"])]
        let vm = try await bootstrappedVM(client)
        vm.input = "第一条"
        vm.send()
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(vm.sending)
        vm.input = "插入补充"
        vm.send()   // sending 中 → inject
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(client.injected, ["插入补充"])
        // 乐观气泡已追加
        XCTAssertTrue(vm.messages.contains { $0.role == "user" && $0.content == "插入补充" })
        vm.stop()
    }

    // TS-121：流结束后 local_ id 对齐成 DB 数字 id
    func testAlignLocalIdsWithDb() async throws {
        let client = ChatMockClient()
        client.streamEvents = [ev("done", ["content": "定稿内容"])]
        let vm = try await bootstrappedVM(client)
        vm.input = "问"
        // 预设 DB 已有本轮落盘（align 时返回数字 id）
        var dbUser = ChatMessage(id: "101", role: "user", content: "问")
        dbUser.dbId = 101
        var dbAssistant = ChatMessage(id: "102", role: "assistant", content: "定稿内容")
        dbAssistant.dbId = 102
        client.dbMessages = [dbUser, dbAssistant]
        vm.send()
        try await Task.sleep(nanoseconds: 500_000_000)
        let assistant = vm.messages.last(where: { $0.role == "assistant" })
        XCTAssertEqual(assistant?.id, "102")
        XCTAssertEqual(assistant?.dbId, 102)
    }
}
