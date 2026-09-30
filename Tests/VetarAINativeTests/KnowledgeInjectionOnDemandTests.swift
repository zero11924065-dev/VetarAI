//
//  KnowledgeInjectionOnDemandTests.swift
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

//  覆盖：
//    · mode(raw:)：缺省/空/未知 → .full（保守默认，不损既有能力）；on_demand/full 映射
//    · knowledgeSection：full 原文透传（含空串）；onDemand 有内容→指引段、空→空
//    · buildSystemPrompt 集成：full 内联知识正文；onDemand 指引段挂【项目知识库】区、
//      正文不出现；记忆两模式均全量（红线/记忆不按需）
//

import XCTest
@testable import VetarAINative

final class KnowledgeInjectionOnDemandTests: XCTestCase {

    // MARK: 1. mode(raw:) 配置映射（保守默认）

    func testModeDefaultsToFull() {
        XCTAssertEqual(KnowledgeInjectionPolicy.mode(raw: nil), .full)
        XCTAssertEqual(KnowledgeInjectionPolicy.mode(raw: ""), .full)
        XCTAssertEqual(KnowledgeInjectionPolicy.mode(raw: "   "), .full)
        XCTAssertEqual(KnowledgeInjectionPolicy.mode(raw: "whatever"), .full,
                       "未知值保守落 full，不损既有能力")
    }

    func testModeOnDemandMapping() {
        XCTAssertEqual(KnowledgeInjectionPolicy.mode(raw: "on_demand"), .onDemand)
        XCTAssertEqual(KnowledgeInjectionPolicy.mode(raw: "full"), .full)
        XCTAssertEqual(KnowledgeInjectionPolicy.configKey, "knowledge_inject_mode")
    }

    // MARK: 2. knowledgeSection 纯逻辑

    func testFullModePassesThroughVerbatim() {
        XCTAssertEqual(KnowledgeInjectionPolicy.knowledgeSection(
            mode: .full, knowledgeText: "【a.md】\n金样正文"), "【a.md】\n金样正文")
        XCTAssertEqual(KnowledgeInjectionPolicy.knowledgeSection(mode: .full, knowledgeText: ""), "")
    }

    func testOnDemandSwapsBodyForGuide() {
        let s = KnowledgeInjectionPolicy.knowledgeSection(
            mode: .onDemand, knowledgeText: "【a.md】\n金样正文")
        XCTAssertEqual(s, KnowledgeInjectionPolicy.onDemandGuide)
        XCTAssertTrue(s.contains("search_knowledge"), "指引必须点名既有拉模式检索工具（REQ-KNW-002 通道）")
        XCTAssertFalse(s.contains("金样正文"), "正文不再内联")
    }

    func testOnDemandEmptyKnowledgeStaysEmpty() {
        XCTAssertEqual(KnowledgeInjectionPolicy.knowledgeSection(mode: .onDemand, knowledgeText: ""),
                       "", "知识库为空不注入指引噪音")
    }

    // MARK: 3. buildSystemPrompt 集成（提示结构稳定 + 记忆不按需）

    private func prompt(knowledge: String, memory: String = "") -> String {
        NativeAgentLoop.buildSystemPrompt(
            agentName: "SubAgent", agentRole: nil, sandboxRoot: "/tmp/x",
            networkSwitch: "off", knowledgeText: knowledge, memoryText: memory)
    }

    func testPromptFullModeInlinesKnowledge() {
        let p = prompt(knowledge: KnowledgeInjectionPolicy.knowledgeSection(
            mode: .full, knowledgeText: "金样正文ABC"))
        XCTAssertTrue(p.contains("【项目知识库】"))
        XCTAssertTrue(p.contains("金样正文ABC"))
    }

    func testPromptOnDemandInjectsGuideNotBodyAndKeepsMemory() {
        let p = prompt(
            knowledge: KnowledgeInjectionPolicy.knowledgeSection(
                mode: .onDemand, knowledgeText: "金样正文ABC"),
            memory: "金样记忆XYZ")
        XCTAssertTrue(p.contains("【项目知识库】"), "指引段仍挂知识库标题下，提示结构稳定")
        XCTAssertTrue(p.contains("search_knowledge"))
        XCTAssertFalse(p.contains("金样正文ABC"), "按需模式正文不内联")
        XCTAssertTrue(p.contains("金样记忆XYZ"), "记忆不按需——两模式均全量注入")
    }
}
