//
//  PackagingHardeningW15Tests.swift
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

//  回归事实（2026-09-27，smoke-evidence-w15/smoke-0.7.5.md + 二分证据链）：
//  W12① 曾给 package_app.sh 的 release 构建加 `-Xswiftc -disable-reflection-metadata`
// （原论证「SwiftUI 视图树不依赖该元数据」为假）——0.7.5(9) 启动 100% SIGTRAP
// 「No ObservableObject of type AppState found」（RootView body 首读环境对象即崩）。
//  机理：SwiftUI 运行时需要 swift5_fieldmd 等反射元数据发现 App/View 结构体内
//  属性包装器（@StateObject/@EnvironmentObject 装配链），剥离后
//  .environmentObject(appState) 注入链断裂。
//  二分（全部真机直跑）：debug（元数据在）活 / release+旗标（未 strip 未打包）崩 /
//  release 无旗标 活 → 唯一变量即此旗标。
//
//  为什么用「打包脚本内容断言」而不是 XCTest 行为测试：XCTest 恒 debug 构建
// （反射元数据在），任何行为测试都拦不住 release 旗标问题；唯一确定性护栏是
//  让引入该旗标的改动在测试期即红。断言对象＝scripts/package_app.sh 文本。
//

import XCTest

final class PackagingHardeningW15Tests: XCTestCase {

    /// 仓根定位：本文件在 <repo>/Tests/VetarAINativeTests/ 下，上两级即仓根。
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // VetarAINativeTests/
            .deletingLastPathComponent()   // Tests/
            .deletingLastPathComponent()   // <repo>/
    }

    private func packageScript() throws -> String {
        let url = Self.repoRoot.appendingPathComponent("scripts/package_app.sh")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// W15 红线：release 打包链永不再引入 -disable-reflection-metadata。
    /// 判定只看非注释行（脚本头注如实记载了该旗标的回退始末，注释不算引入）。
    func testPackageScriptNeverStripsReflectionMetadata() throws {
        let script = try packageScript()
        let codeLines = script
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("#") }
            .joined(separator: "\n")
        XCTAssertFalse(codeLines.contains("-disable-reflection-metadata"),
                       "W15 回归红线：package_app.sh 不得再引入 "
                       + "-disable-reflection-metadata（剥离 SwiftUI 反射元数据 → "
                       + "启动即崩 No ObservableObject of type AppState found；"
                       + "根因见本文件头注与 smoke-evidence-w15）")
    }

    /// 加固保留项不丢：strip 与 dSYM 归档仍在脚本内（轻加固口径＝符号精简，
    /// 不动元数据段）
    func testPackageScriptKeepsStripAndDsymArchive() throws {
        let script = try packageScript()
        XCTAssertTrue(script.contains("dsymutil"), "dSYM 归档步骤应保留")
        XCTAssertTrue(script.contains("/usr/bin/strip"), "strip 符号精简应保留")
    }
}
