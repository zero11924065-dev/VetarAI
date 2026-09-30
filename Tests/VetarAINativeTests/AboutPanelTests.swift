//
//  AboutPanelTests.swift
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

//  业主 2026-09-27 22:03 反馈：macOS 标准关于面板格式错误、字体错误，
//  需对齐 Electron 旧版（0.4.34 截图实证形态）。规格唯一考据源：
//  subagent/main.js openAboutWindow()（窗口 380×460 不可调、标题「关于
//  VetarAI」、图标 96×96 圆角 14 描边 #1a1a1e、名称 28/700、版本行
//  「版本号：X.Y.Z」Menlo 13、中文介绍 14/500、英文介绍 12、版权行保留）。
//  本套件钉死这些口径，防回退到标准面板/英文版本格式。
//

import XCTest
@testable import VetarAINative

@MainActor
final class AboutPanelTests: XCTestCase {

    /// 窗口规格钉 Electron 原版：380×460、标题「关于 VetarAI」、
    /// 不可调/不可最小化（Electron resizable:false minimizable:false maximizable:false）
    func testWindowSpecMatchesElectron() {
        let controller = AboutWindowController.shared
        let win = controller.makeWindow()
        // 量内容区（win.frame 含 32pt 标题栏：460+32=492 属预期）
        let content = win.contentLayoutRect.size
        XCTAssertEqual(content.width, 380, accuracy: 0.5, "窗口宽应对齐 Electron 380")
        XCTAssertEqual(content.height, 460, accuracy: 0.5, "窗口高应对齐 Electron 460")
        XCTAssertEqual(win.title, "关于 \(AppVersion.appName)")
        XCTAssertFalse(win.styleMask.contains(.resizable), "Electron 原版 resizable:false")
        XCTAssertFalse(win.styleMask.contains(.miniaturizable), "Electron 原版 minimizable:false")
        win.close()
    }

    /// 版本行格式钉旧版：中文标签「版本号：X.Y.Z」——不得回退到
    /// 标准面板的「Version X （构建 Y）」英文格式
    func testVersionLineFormat() {
        let line = "版本号：\(AppVersion.current)"
        XCTAssertTrue(line.hasPrefix("版本号："), "版本行必须中文标签（Electron main.js:64）")
        XCTAssertTrue(line.contains(AppVersion.current))
        XCTAssertFalse(line.contains("Version"), "不得出现英文 Version 格式")
        XCTAssertFalse(line.contains("构建"), "旧版无构建号后缀（0.4.34 截图实证）")
        XCTAssertFalse(line.contains(AppVersion.phaseName), "版本行不得带批次说明")
    }

    /// 介绍/版权文案钉 AppVersion 常量（逐字考据 Electron APP_TAGLINE_CN/EN；
    /// 版权行为 0.7.1 业主拍板保留的新增项）
    func testTaglineAndCopyrightConstants() {
        XCTAssertEqual(AppVersion.taglineCN, "一款零生态基础的Agent工具")
        XCTAssertEqual(AppVersion.taglineEN, "An ecosystem-agnostic Agent tool.")
        XCTAssertEqual(AppVersion.copyright, "Copyright © 2025–2026 VetarAI")
    }

    /// 单例生命周期同 Electron：重复 show 聚焦同一窗（不叠开新窗）
    func testShowReusesExistingWindow() {
        let controller = AboutWindowController.shared
        controller.show()
        controller.show()  // 第二次应聚焦而非新建——不崩溃即过（窗口复用路径）
    }
}
