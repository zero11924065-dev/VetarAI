//
//  ChatTextFilterTests.swift
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

//  空 think 块渲染滤除纯函数钉桩：
//    · 闭合空块 / 纯空白块（空格·换行·Tab）剔除
//    · 多块混合：空块剥、非空块原样保留（现有思考块 UI 口径不动）
//    · 流式安全：未闭合 <think> 尾部原样保留（中间态非空内容不误杀）
//    · 无 think 文本零改动；未剔除任何块时首尾空白不裁
//    · 幂等：剔除结果再过一遍不变
//

import XCTest
@testable import VetarAINative

final class ChatTextFilterTests: XCTestCase {

    // MARK: - 空块剔除（回执现象：气泡原文显示空 <think></think>）

    func testEmptyClosedBlockStripped() {
        XCTAssertEqual(ChatTextFilter.stripEmptyThinkBlocks("<think></think>答案是 42。"),
                       "答案是 42。")
    }

    func testWhitespaceOnlyBlockStripped() {
        // 纯空白内容（空格/换行/Tab）视同空块
        XCTAssertEqual(ChatTextFilter.stripEmptyThinkBlocks("<think>  \n\t </think>回答"), "回答")
        XCTAssertEqual(ChatTextFilter.stripEmptyThinkBlocks("<think>\n\n</think>回答"), "回答")
    }

    func testWholeMessageIsEmptyBlock() {
        // 整条消息只有一个空块 → 滤后为空（气泡等效尚未产出正文）
        XCTAssertEqual(ChatTextFilter.stripEmptyThinkBlocks("<think></think>"), "")
    }

    func testEmptyBlockAtTailStripped() {
        XCTAssertEqual(ChatTextFilter.stripEmptyThinkBlocks("先说结论。<think></think>"),
                       "先说结论。")
    }

    func testMultipleEmptyBlocksStripped() {
        XCTAssertEqual(ChatTextFilter.stripEmptyThinkBlocks(
            "<think></think>回答一<think> </think>回答二"), "回答一回答二")
    }

    // MARK: - 非空块保留（回执口径：非空思考块按现有思考块 UI 正常展示）

    func testNonEmptyBlockPreservedVerbatim() {
        let input = "<think>让我想想…答案是 42。</think>答案是 42。"
        XCTAssertEqual(ChatTextFilter.stripEmptyThinkBlocks(input), input)
    }

    func testMixedEmptyAndNonEmptyBlocks() {
        // 空块剥、非空块原样留（含标签）
        XCTAssertEqual(ChatTextFilter.stripEmptyThinkBlocks(
            "<think></think><think>真思考</think>回答"), "<think>真思考</think>回答")
    }

    // MARK: - 流式安全（未闭合尾部不误杀）

    func testUnclosedTailPreserved() {
        // 流式中间态：<think> 已开未合，内容还在路上——原样保留
        let input = "<think>正在推理中"
        XCTAssertEqual(ChatTextFilter.stripEmptyThinkBlocks(input), input)
    }

    func testUnclosedEmptyTailPreserved() {
        // 刚开出 <think> 尚无内容：此刻判空为时过早，保留待闭合后再滤
        let input = "<think>"
        XCTAssertEqual(ChatTextFilter.stripEmptyThinkBlocks(input), input)
    }

    func testEmptyBlocksBeforeUnclosedTailStillStripped() {
        // 已闭合的空块照剥；末尾未闭合段原样保留
        XCTAssertEqual(ChatTextFilter.stripEmptyThinkBlocks(
            "<think></think>答案。<think>未闭合"), "答案。<think>未闭合")
    }

    // MARK: - 零改动路径

    func testNoThinkTextUntouched() {
        let input = "普通的回答内容。"
        XCTAssertEqual(ChatTextFilter.stripEmptyThinkBlocks(input), input)
    }

    func testNoStripNoTrim() {
        // 未剔除任何块时逐字返回原文（有意的首尾空白不裁）
        let input = "  缩进保留  "
        XCTAssertEqual(ChatTextFilter.stripEmptyThinkBlocks(input), input)
        let nonEmpty = "  <think>想</think>答案  "
        XCTAssertEqual(ChatTextFilter.stripEmptyThinkBlocks(nonEmpty), nonEmpty)
    }

    func testMentionsOfTagInProsePreserved() {
        // 正文里正常出现 <think> 字样（未闭合）——防误伤
        let input = "介绍一下 <think> 标签的用法"
        XCTAssertEqual(ChatTextFilter.stripEmptyThinkBlocks(input), input)
    }

    // MARK: - 幂等（渲染层 15fps 反复调用）

    func testIdempotent() {
        let input = "<think></think>\n\n回答<think>留</think>尾"
        let once = ChatTextFilter.stripEmptyThinkBlocks(input)
        XCTAssertEqual(ChatTextFilter.stripEmptyThinkBlocks(once), once)
    }
}
