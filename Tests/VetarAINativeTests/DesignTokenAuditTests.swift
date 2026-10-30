//
//  DesignTokenAuditTests.swift
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

//  ① 雾蓝族退役：Sources 下不得再出现方向2 前的雾蓝 hex（Tailwind blue 系）——
//    朱砂族已全仓替换，复现即回归；
//  ② 退役字阶令牌名不得复活：Typo.display28 / Typo.title2 / Typo.railLabel
//    已收编为 display(24 宋体) / title(17 宋体) / micro(11)。
//

import XCTest
import Foundation

final class DesignTokenAuditTests: XCTestCase {

    /// 仓内 Sources/VetarAINative（#filePath = <repo>/Tests/VetarAINativeTests/DesignTokenAuditTests.swift）。
    private static func repoSourcesDir(_ file: StaticString = #filePath) -> URL {
        URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent()   // VetarAINativeTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // <repo>
            .appendingPathComponent("Sources/VetarAINative", isDirectory: true)
    }

    private func allSwiftLines() -> [(file: String, line: Int, text: String)] {
        let dir = Self.repoSourcesDir()
        guard let en = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else { return [] }
        var out: [(String, Int, String)] = []
        for case let url as URL in en where url.pathExtension == "swift" {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for (idx, line) in text.components(separatedBy: "\n").enumerated() {
                out.append((url.lastPathComponent, idx + 1, line))
            }
        }
        return out
    }

    /// 方向2 前的雾蓝族 hex（Tailwind blue 系），2026-10-19 起全仓退役。
    private static let retiredMistBlueHex: [String] = [
        "3B82F6", "2563EB", "E9F0FC", "C2D7F8", "F4F8FE", "1E40AF",
        "7AA5F8", "2A3A55", "3B5380", "242E42", "93B4FA",
    ]

    func testMistBlueHexStayGone() {
        let hits = allSwiftLines().filter { (_, _, line) in
            Self.retiredMistBlueHex.contains { hex in
                line.range(of: hex, options: .caseInsensitive) != nil
            }
        }
        XCTAssertTrue(hits.isEmpty,
                      "雾蓝族 hex 复现（方向2 朱砂族已全仓替换）：\n" +
                      hits.map { "\($0.file):\($0.line)  \($0.text)" }.joined(separator: "\n"))
    }

    func testRetiredTypoTokensStayGone() {
        let retired = ["Typo.display28", "Typo.title2", "Typo.railLabel"]
        let hits = allSwiftLines().filter { (_, _, line) in
            retired.contains { line.contains($0) }
        }
        XCTAssertTrue(hits.isEmpty,
                      "退役字阶令牌复现（已收编 display/title/micro）：\n" +
                      hits.map { "\($0.file):\($0.line)  \($0.text)" }.joined(separator: "\n"))
    }
}
