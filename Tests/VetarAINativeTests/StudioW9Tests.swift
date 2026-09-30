//
//  StudioW9Tests.swift
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

//  背景：业主实测触控板左右正确、垂直反（下拉内容上移），且鼠标滚轮平移近乎不动
//  （行滚动未乘行高系数）。根因：StudioCanvasView 写死 x+=deltaX/y-=deltaY，
//  未按 macOS delta 语义映射，行滚动未折算像素。
//
//  符号口径锚点（改此处前必读）：
//    · Apple isDirectionInvertedFromDevice 文档：自然滚动下 deltas 两轴已被系统反转，
//      成「内容跟手」方向——app 按传统语义实现即可两设备皆对，无需逐事件分流；
//    · 业主实测（自然滚动开）：触控板右推 deltaX>0 且内容右移为正确（跟手）；
//    · 传统语义：deltaY>0 = scroll up = 视口上移 = 内容下移；
//      deltaX>0 = scroll left = 视口左移 = 内容右移（shift+上滚 = 向左滚）；
//    · 缩放锚定「向上 = 放大」：触控板上推 deltaY<0，需按 inverted 取反归一。
//
//  覆盖：
//    P1–P4  触控板平移（precise）：上推/下拉/右推/左推 四方向内容跟手
//    P5–P8  鼠标平移（行滚动）：上滚/下滚/水平左/水平右 视口语义正确
//    P9–P10 行滚动系数：×16 折算 / precise 不折算
//    Z1–Z4  Cmd+滚轮缩放：鼠标上滚放大/下滚缩小；触控板上推放大/下推缩小
//

import XCTest
import CoreGraphics
@testable import VetarAINative

final class StudioW9ScrollTests: XCTestCase {

    // MARK: - P 触控板平移（自然滚动，precise 像素 delta，与手指同向）

    /// P1 上推（deltaY<0）→ 内容向上移（pan.y<0，跟手）
    func testP1_trackpad_pushUp_contentMovesUp() {
        let d = StudioCanvasLayout.scrollPanDelta(hasPreciseDeltas: true, deltaX: 0, deltaY: -32)
        XCTAssertEqual(d.y, -32, accuracy: 0.001, "上推内容应向上（y 向下为正 → 负）")
        XCTAssertEqual(d.x, 0, accuracy: 0.001)
    }

    /// P2 下拉（deltaY>0）→ 内容向下移（跟手；旧实现 -=deltaY 在此反向，DBG-165 根因）
    func testP2_trackpad_pullDown_contentMovesDown() {
        let d = StudioCanvasLayout.scrollPanDelta(hasPreciseDeltas: true, deltaX: 0, deltaY: 32)
        XCTAssertEqual(d.y, 32, accuracy: 0.001, "下拉内容应向下（跟手）")
    }

    /// P3 右推（deltaX>0）→ 内容向右移（业主实测现状正确，保持回归）
    func testP3_trackpad_pushRight_contentMovesRight() {
        let d = StudioCanvasLayout.scrollPanDelta(hasPreciseDeltas: true, deltaX: 25, deltaY: 0)
        XCTAssertEqual(d.x, 25, accuracy: 0.001, "右推内容应向右（业主实测基准，勿回归）")
    }

    /// P4 左推（deltaX<0）→ 内容向左移
    func testP4_trackpad_pushLeft_contentMovesLeft() {
        let d = StudioCanvasLayout.scrollPanDelta(hasPreciseDeltas: true, deltaX: -25, deltaY: 0)
        XCTAssertEqual(d.x, -25, accuracy: 0.001)
    }

    // MARK: - P 鼠标平移（行滚动，传统视口语义）

    /// P5 上滚（deltaY>0）→ 视口上移 = 内容下移（pan.y>0）
    func testP5_mouse_wheelUp_contentMovesDown() {
        let d = StudioCanvasLayout.scrollPanDelta(hasPreciseDeltas: false, deltaX: 0, deltaY: 1)
        XCTAssertEqual(d.y, StudioCanvasLayout.lineScrollStep, accuracy: 0.001,
                       "鼠标上滚 = 视口向上 = 内容向下（传统语义）")
    }

    /// P6 下滚（deltaY<0）→ 视口下移 = 内容上移
    func testP6_mouse_wheelDown_contentMovesUp() {
        let d = StudioCanvasLayout.scrollPanDelta(hasPreciseDeltas: false, deltaX: 0, deltaY: -1)
        XCTAssertEqual(d.y, -StudioCanvasLayout.lineScrollStep, accuracy: 0.001)
    }

    /// P7 水平左滚（deltaX>0 = scroll left）→ 视口左移 = 内容右移
    func testP7_mouse_wheelLeft_contentMovesRight() {
        let d = StudioCanvasLayout.scrollPanDelta(hasPreciseDeltas: false, deltaX: 1, deltaY: 0)
        XCTAssertEqual(d.x, StudioCanvasLayout.lineScrollStep, accuracy: 0.001,
                       "scroll left = 视口向左 = 内容向右")
    }

    /// P8 水平右滚（deltaX<0 = scroll right）→ 视口右移 = 内容左移
    func testP8_mouse_wheelRight_contentMovesLeft() {
        let d = StudioCanvasLayout.scrollPanDelta(hasPreciseDeltas: false, deltaX: -1, deltaY: 0)
        XCTAssertEqual(d.x, -StudioCanvasLayout.lineScrollStep, accuracy: 0.001)
    }

    // MARK: - P 行滚动系数

    /// P9 行滚动 ×16：3 行 = 48pt（旧实现未折算，鼠标滚一格仅 1pt 近乎不动）
    func testP9_lineScroll_multipliedByLineStep() {
        let d = StudioCanvasLayout.scrollPanDelta(hasPreciseDeltas: false, deltaX: 0, deltaY: 3)
        XCTAssertEqual(d.y, 48, accuracy: 0.001, "行滚动必须乘行高系数 16")
    }

    /// P10 像素滚动不折算（触控板 delta 即像素）
    func testP10_preciseScroll_notMultiplied() {
        let d = StudioCanvasLayout.scrollPanDelta(hasPreciseDeltas: true, deltaX: 7.5, deltaY: -7.5)
        XCTAssertEqual(d.x, 7.5, accuracy: 0.001)
        XCTAssertEqual(d.y, -7.5, accuracy: 0.001)
    }

    // MARK: - Z Cmd+滚轮缩放（统一「向上 = 放大」）

    /// Z1 鼠标上滚（inverted=false, deltaY>0）→ 放大（factor>1）
    func testZ1_mouse_wheelUp_zoomsIn() {
        let f = StudioCanvasLayout.scrollZoomFactor(isInverted: false,
                                                    hasPreciseDeltas: false, deltaY: 1)
        XCTAssertGreaterThan(f, 1.0, "鼠标上滚应放大")
    }

    /// Z2 鼠标下滚 → 缩小
    func testZ2_mouse_wheelDown_zoomsOut() {
        let f = StudioCanvasLayout.scrollZoomFactor(isInverted: false,
                                                    hasPreciseDeltas: false, deltaY: -1)
        XCTAssertLessThan(f, 1.0)
    }

    /// Z3 触控板上推（inverted=true, deltaY<0）→ 放大（取反归一）
    func testZ3_trackpad_pushUp_zoomsIn() {
        let f = StudioCanvasLayout.scrollZoomFactor(isInverted: true,
                                                    hasPreciseDeltas: true, deltaY: -20)
        XCTAssertGreaterThan(f, 1.0, "触控板上推应同样放大（与鼠标口径统一）")
    }

    /// Z4 触控板下推 → 缩小；且行滚动每格缩放幅度 ≈ 1.0015^144
    func testZ4_trackpad_pushDown_zoomsOut_andLineStepMagnitude() {
        let fTouch = StudioCanvasLayout.scrollZoomFactor(isInverted: true,
                                                         hasPreciseDeltas: true, deltaY: 20)
        XCTAssertLessThan(fTouch, 1.0)
        let fLine = StudioCanvasLayout.scrollZoomFactor(isInverted: false,
                                                        hasPreciseDeltas: false, deltaY: 1)
        XCTAssertEqual(Double(fLine), pow(1.0015, 48), accuracy: 0.0001,
                       "行滚动每格 = 1.0015^(3×16)")
    }
}
