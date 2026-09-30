//
//  AXIdentifierAuditTests.swift
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

//  全仓 accessibilityIdentifier 静态审计：
//  ① 字面量 id 全局唯一——同 id 多实例则 AX 命中查询返回不可预期元素（DBG-160 教训）；
//    动态插值 id（"...\(x)"）由调用方拼区分后缀，不在字面量审计面内。
//  ② 容器传染回归——已移除的容器 id 不得复现：
//    SwiftUI 容器层挂 id 会下沉覆盖子元素自身 id（activation.overlay 覆盖
//    activation.codeField 为首发案例），原则「id 只挂叶子/交互元素，容器不挂」。
//

import XCTest
import Foundation

final class AXIdentifierAuditTests: XCTestCase {

    /// 仓内 Sources/VetarAINative（#filePath = <repo>/Tests/VetarAINativeTests/AXIdentifierAuditTests.swift）。
    private static func repoSourcesDir(_ file: StaticString = #filePath) -> URL {
        URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent()   // VetarAINativeTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // <repo>
            .appendingPathComponent("Sources/VetarAINative", isDirectory: true)
    }

    /// 提取全部 .accessibilityIdentifier("字面量")（不含插值），返回 [(id, file, line)]。
    private func collectLiteralIds() -> [(id: String, file: String, line: Int)] {
        let dir = Self.repoSourcesDir()
        guard let en = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else { return [] }
        var out: [(String, String, Int)] = []
        let pattern = #/\.accessibilityIdentifier\("([^"]+)"\)/#
        for case let url as URL in en where url.pathExtension == "swift" {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for (idx, line) in text.components(separatedBy: "\n").enumerated() {
                for m in line.matches(of: pattern) {
                    let id = String(m.1)
                    if id.contains(#"\("#) { continue }   // 动态插值 id 跳过
                    out.append((id, url.lastPathComponent, idx + 1))
                }
            }
        }
        return out
    }

    func testLiteralIdsGloballyUnique() {
        let all = collectLiteralIds()
        XCTAssertGreaterThan(all.count, 100, "审计应扫到大量字面量 id（路径推导失败？）")
        var seen: [String: (file: String, line: Int)] = [:]
        var dups: [String] = []
        for (id, file, line) in all {
            if let first = seen[id] {
                dups.append("\(id)  首见 \(first.file):\(first.line)  复见 \(file):\(line)")
            } else {
                seen[id] = (file, line)
            }
        }
        XCTAssertTrue(dups.isEmpty,
                      "字面量 AX id 撞车（DBG-160 同 id 多实例）：\n" + dups.joined(separator: "\n"))
    }

    func testRemovedContainerIdsStayGone() {
        // 2026-09-25 DBG-160 修复移除的容器 id（容器挂 id 下沉覆盖子元素 id 的传染点）
        let removed: Set<String> = [
            "activation.overlay", "license.trialBanner", "trialExpired.card", "paywall.card",
            "account.card", "account.devices", "account.server", "account.unbindDialog",
            "studio.emptyCard", "studio.pausedCard", "studio.summaryCard", "studio.interventionCard",
            "studio.reviewGraph", "studio.reviewBar", "studio.canvas", "studio.filterBar",
            "studio.zoomControl", "settingsOverlay", "settings.page", "workflowEditor",
            "workflowCanvas", "workflowApprovalCard", "workflowRuns", "cuMacroSelectedCard",
            // 2026-09-25 二次补网（0.7.1 签名包冒烟实证漏网）：studio.panel 根容器
            // 传染全部子孙（叶子 id 全被覆盖成 studio.panel）、studio.topBar 同根、
            // studio.concurrencyStepper 覆盖 − / 文本 / + 三子元素（axinfect 全扫实证）。
            "studio.panel", "studio.topBar", "studio.concurrencyStepper",
        ]
        let all = Set(collectLiteralIds().map { $0.id })
        let back = removed.intersection(all)
        XCTAssertTrue(back.isEmpty, "容器 id 复现（DBG-160 回归）：\(back.sorted())")
    }
}
