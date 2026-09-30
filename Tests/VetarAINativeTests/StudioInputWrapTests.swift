//
//  StudioInputWrapTests.swift
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

//  业主 2026-09-27 反馈：「工作室输入框不会自动换行，而是无限延伸」
//  （截图=工作室空态需求框）。本测试无头定性：VPlaceholderTextEditor
//  （需求框/便签框共用组件）在 544pt 宽下，长无空格文本是否换行；
//  并钉死换行配置三元组（不横向扩展 + 容器随宽 + 仅纵向滚动条）防回归。
//

import XCTest
import SwiftUI
@testable import VetarAINative

@MainActor
final class StudioInputWrapTests: XCTestCase {

    /// 无空格长文本（中英文混合无断点）在需求框宽度下必须折成多行
    func testPlaceholderEditorWrapsLongText() throws {
        let longText = String(repeating: "这是一段很长的中文混排文本NoSpaceBreakHere1234567890", count: 12)
        let host = NSHostingView(rootView:
            VPlaceholderTextEditor(text: .constant(longText), placeholder: "p", fontSize: 13)
                .frame(width: 544, height: 96))
        host.frame = NSRect(x: 0, y: 0, width: 544, height: 96)
        host.layoutSubtreeIfNeeded()

        let textView = try XCTUnwrap(findTextView(in: host), "宿主内应能找到 NSTextView")
        guard let lm = textView.layoutManager, let tc = textView.textContainer else {
            return XCTFail("NSTextView 缺 layoutManager/textContainer")
        }
        lm.ensureLayout(for: tc)

        // 行碎片数 > 1 即发生换行（不换行则整段一个碎片、横向无限延伸）
        var lineCount = 0
        var idx = 0
        while idx < lm.numberOfGlyphs {
            var r = NSRange()
            lm.lineFragmentRect(forGlyphAt: idx, effectiveRange: &r)
            lineCount += 1
            idx = NSMaxRange(r)
        }
        XCTAssertGreaterThan(lineCount, 1, "长文本必须换行（业主实测：不换行横向无限延伸）")
        // 容器宽不得超过视图宽（换行几何基础）
        XCTAssertLessThanOrEqual(tc.containerSize.width, textView.bounds.width + 1)
    }

    /// 换行配置三元组钉桩：isHorizontallyResizable=false /
    /// widthTracksTextView=true / 只有纵向滚动条——任一被改都会复发"无限延伸"
    func testWrapConfigTriplet() throws {
        let host = NSHostingView(rootView:
            VPlaceholderTextEditor(text: .constant(""), placeholder: "p")
                .frame(width: 544, height: 96))
        host.frame = NSRect(x: 0, y: 0, width: 544, height: 96)
        host.layoutSubtreeIfNeeded()

        let textView = try XCTUnwrap(findTextView(in: host))
        XCTAssertFalse(textView.isHorizontallyResizable, "横向可扩展=不换行根因")
        XCTAssertEqual(textView.textContainer?.widthTracksTextView, true)
        let scroll = try XCTUnwrap(textView.enclosingScrollView)
        XCTAssertTrue(scroll.hasVerticalScroller)
        XCTAssertFalse(scroll.hasHorizontalScroller, "横向滚动条=不换行根因")
    }

    private func findTextView(in view: NSView) -> NSTextView? {
        if let tv = view as? NSTextView { return tv }
        for sub in view.subviews {
            if let found = findTextView(in: sub) { return found }
        }
        return nil
    }

    // MARK: - F3/F4（0.7.12 实测修复：tv 宽漂移裁剪中间行 / 点击无光标 beep）

    /// F3：tv frame 被外力漂移到 1024 宽、x=-480（运行中应用 AX 实测形态）后，
    /// 下一次 layout 必须回钉「x=0、宽=可视宽」；clip 横向原点同步归零。
    func testLayoutPinsTextViewGeometryBack() throws {
        let host = NSHostingView(rootView:
            VPlaceholderTextEditor(text: .constant("三行\n文本\n内容"), placeholder: "p")
                .frame(width: 544, height: 96))
        host.frame = NSRect(x: 0, y: 0, width: 544, height: 96)
        host.layoutSubtreeIfNeeded()

        let textView = try XCTUnwrap(findTextView(in: host))
        let scroll = try XCTUnwrap(textView.enclosingScrollView)

        // 模拟实测漂移形态（E2E 复现的故障几何）
        textView.frame = NSRect(x: -480, y: 0, width: 1024, height: textView.frame.height)
        scroll.contentView.bounds = NSRect(x: 480, y: 0,
                                           width: scroll.contentView.bounds.width,
                                           height: scroll.contentView.bounds.height)

        // 生产中窗口拖放/SwiftUI 重排必然触发 scroll.layout()；测试显式标脏触发同一条路径
        scroll.needsLayout = true
        scroll.layoutSubtreeIfNeeded()

        XCTAssertEqual(textView.frame.origin.x, 0, "tv 原点 x 必须回钉 0（漂移即中间行被裁）")
        XCTAssertEqual(textView.frame.size.width, scroll.contentSize.width,
                       "tv 宽必须回钉可视宽（漂移 1024 即不换行横向延伸）")
        XCTAssertEqual(scroll.contentView.bounds.origin.x, 0,
                       "clip 横向原点必须归零（视口水平切片=只渲染 1、3 行）")
    }

    /// F4②：tv 高度铺满可视区——空文（内容高 ~24pt）在 96pt 框内，
    /// tv frame 必须 ≥ 可视高（下方不再有 NSClipView 死区：点击即聚焦、按键不 beep）。
    func testTextViewFillsViewportHeight() throws {
        let host = NSHostingView(rootView:
            VPlaceholderTextEditor(text: .constant(""), placeholder: "p")
                .frame(width: 544, height: 96))
        host.frame = NSRect(x: 0, y: 0, width: 544, height: 96)
        host.layoutSubtreeIfNeeded()

        let textView = try XCTUnwrap(findTextView(in: host))
        let scroll = try XCTUnwrap(textView.enclosingScrollView)
        XCTAssertGreaterThanOrEqual(textView.frame.height, scroll.contentSize.height - 0.5,
                                    "tv 必须铺满可视高（空文收缩=下半区死区点击不聚焦）")
    }

    /// F4①：占位 label 命中测试穿透（复用 ComposerPassthroughLabel）——
    /// 点中占位文字不再吞击（吞击=无光标+beep 的另一死区）。
    func testPlaceholderLabelHitTestPassthrough() throws {
        let host = NSHostingView(rootView:
            VPlaceholderTextEditor(text: .constant(""), placeholder: "请输入需求")
                .frame(width: 544, height: 96))
        host.frame = NSRect(x: 0, y: 0, width: 544, height: 96)
        host.layoutSubtreeIfNeeded()

        let textView = try XCTUnwrap(findTextView(in: host))
        let label = textView.subviews.compactMap { $0 as? NSTextField }.first
        XCTAssertNotNil(label, "空文应已创建占位 label")
        XCTAssertNil(label?.hitTest(NSPoint(x: 5, y: 5)),
                     "占位 label 必须命中穿透（点击落到底下 NSTextView 聚焦）")
    }

    /// F3 配置钉桩：横向弹性关闭（触控板横滑不再把 clip 原点推出 0）。
    func testHorizontalElasticityOff() throws {
        let host = NSHostingView(rootView:
            VPlaceholderTextEditor(text: .constant(""), placeholder: "p")
                .frame(width: 544, height: 96))
        host.frame = NSRect(x: 0, y: 0, width: 544, height: 96)
        host.layoutSubtreeIfNeeded()

        let textView = try XCTUnwrap(findTextView(in: host))
        let scroll = try XCTUnwrap(textView.enclosingScrollView)
        XCTAssertEqual(scroll.horizontalScrollElasticity, .none,
                       "横向弹性必须关闭（开着=横滑漂移 F3 复发口）")
    }

    // MARK: - 插话条换行改造（0.7.6 业主反馈：插话条单行不换行无限延伸）

    /// 度量纯函数钉桩：空文单行高、长文折多行、超 3 行钳顶
    func testInterjectMetricsLineClamping() {
        let one = StudioInterjectMetrics.editorHeight(text: "", wrapWidth: 360)
        XCTAssertEqual(one, StudioInterjectMetrics.lineHeight + StudioInterjectMetrics.editorInsetV)
        let short = StudioInterjectMetrics.editorHeight(text: "你好", wrapWidth: 360)
        XCTAssertEqual(short, one, "短文本一行高")
        let long = StudioInterjectMetrics.editorHeight(
            text: String(repeating: "很长的一段插话内容没有断点", count: 30), wrapWidth: 360)
        XCTAssertGreaterThan(long, one, "长文本必须折行加高")
        XCTAssertLessThanOrEqual(long,
            CGFloat(StudioInterjectMetrics.maxLines) * StudioInterjectMetrics.lineHeight
                + StudioInterjectMetrics.editorInsetV,
            "超 3 行钳顶（内部滚动），条体不无限长高")
    }

    /// Enter 语义钉桩（与智能中心 ComposerTextView 同口径）：
    /// 裸 Enter 有钩子=提交不插换行；Shift+Enter=换行
    func testInterjectEnterSemantics() throws {
        var submitted = false
        let tv = PlaceholderNSTextView(frame: NSRect(x: 0, y: 0, width: 360, height: 60))
        tv.onSubmitEnter = { submitted = true; return true }
        tv.string = "插话内容"

        let enter = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil,
            characters: "\r", charactersIgnoringModifiers: "\r",
            isARepeat: false, keyCode: 36))
        tv.keyDown(with: enter)
        XCTAssertTrue(submitted, "裸 Enter 必须触发提交")
        XCTAssertFalse(tv.string.contains("\n"), "提交后不得插入换行")

        submitted = false
        let shiftEnter = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.shift],
            timestamp: 0, windowNumber: 0, context: nil,
            characters: "\r", charactersIgnoringModifiers: "\r",
            isARepeat: false, keyCode: 36))
        tv.keyDown(with: shiftEnter)
        XCTAssertFalse(submitted, "Shift+Enter 不触发提交")
        XCTAssertTrue(tv.string.contains("\n"), "Shift+Enter 必须插入换行")
    }
}
