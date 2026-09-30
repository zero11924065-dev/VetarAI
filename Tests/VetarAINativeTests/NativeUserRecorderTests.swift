//
//  NativeUserRecorderTests.swift
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

//  逐条翻译 subagent/sidecar/computer_use/test_cu_user_record.py 的归并层用例
//  （⛔ 只读行为规格源；语义以 Python 源码为准；H 组端点契约见
//  NativeCUMacroEndpointTests）：
//    · A 组 打字聚合与截断：连续字符聚合 / 回车·退格截断 / 切焦点截断 / 点击截断 /
//      shift 变体 + IME text 直达 / option+字母无 text 跳过
//    · B 组 鼠标归并：单击暂缓定案（双击窗口 0.5s）/ 同点双击合并 double_click /
//      超窗·位移超阈两 click / 右键 right_click / 拖拽 drag_to 立即定案 / 中键记 click
//    · C 组 hotkey 与特殊键：cmd/ctrl 组合键 / 截断聚合 / 纯修饰键不记 /
//      option+方向键 / shift+return
//    · D 组 密码防护：安全输入段整段不记（连长度都不记，只计数）/ 焦点密码框二道闸 /
//      段前后明文各自成段
//    · E 组 自身过滤：VetarAI/Electron/ai.vetar.* 前台事件不录 / 只截断不吞并
//    · F 组 元素语义富化：命中写 element / 未命中回落坐标 + frontmost app
//    · G 组 生命周期：硬上限自动停一次 / stop flush 收尾全落 / stop 幂等
//    · R 组（Bug6）授权请求决策核 requestListenAccessFlow：已授权短路 / 探测 tap
//      建成短路 / 探测登记→请求→复核全序 / 复核 nil 回落 request 返回值
//
//  ⛔ 零真实 TCC/键鼠：全部假探针 + 直接喂 ingest（Python _mk_rec/_feed 同款纪律）；
//  真 tap/CFRunLoop/系统弹窗属真机冒烟（父代理）。
//

import XCTest
@testable import VetarAINative

final class NativeUserRecorderTests: XCTestCase {

    // ── _mk_rec 同构：全假探针录制器工厂（绝不 start()，直接 ingest）──
    private var steps: [NativeUserRecorder.Step] = []
    private var front: (String, String, Int32) = ("Notes", "com.apple.Notes", 4242)
    private var secure = false
    private var focused = false
    private var hitStub: NativeCUElementHit?
    private var timeoutFired = 0

    override func setUp() {
        super.setUp()
        steps = []
        front = ("Notes", "com.apple.Notes", 4242)
        secure = false
        focused = false
        hitStub = nil
        timeoutFired = 0
    }

    private func makeRec(maxSeconds: Double = 600.0,
                         withTimeout: Bool = false) -> NativeUserRecorder {
        var onTimeout: (@Sendable () -> Void)?
        if withTimeout {
            onTimeout = { [self] in self.timeoutFired += 1 }
        }
        return NativeUserRecorder(
            onStep: { [self] step in self.steps.append(step) },
            onTimeout: onTimeout,
            maxSeconds: maxSeconds,
            probes: NativeUserRecorder.Probes(
                front: { [self] in self.front },
                hit: { [self] (_: Double, _: Double) in self.hitStub },
                secure: { [self] in self.secure },
                focusedSecure: { [self] in self.focused },
                now: { 1000.0 }))
    }

    // ── 事件构造（_key/_down/_up 同构；flags 常量与 Python _F_* 同值）──
    private let F_SHIFT = NativeUserRecorder.flagShift
    private let F_OPT = NativeUserRecorder.flagOpt
    private let F_CMD = NativeUserRecorder.flagCmd

    private func key(_ keycode: Int, flags: UInt64 = 0, text: String = "",
                     ts: Double = 1.0) -> NativeUserRecorder.RawEvent {
        .init(kind: .key, ts: ts, keycode: keycode, flags: flags, text: text)
    }

    private func down(_ x: Double, _ y: Double, button: String = "left",
                      ts: Double = 1.0) -> NativeUserRecorder.RawEvent {
        .init(kind: .mouseDown, ts: ts, x: x, y: y, button: button)
    }

    private func up(_ x: Double, _ y: Double, button: String = "left",
                    ts: Double = 1.0) -> NativeUserRecorder.RawEvent {
        .init(kind: .mouseUp, ts: ts, x: x, y: y, button: button)
    }

    private func feed(_ rec: NativeUserRecorder, _ events: NativeUserRecorder.RawEvent...) {
        for ev in events { rec.ingest(ev) }
    }

    private var types: [String] {
        steps.filter { $0.action == "type" }.compactMap { $0.payload["text"]?.string }
    }
    private var keys: [String] {
        steps.filter { $0.action == "key" }.compactMap { $0.payload["keys"]?.string }
    }
    private var clicks: [(String, Double?, Double?)] {
        steps.filter { ["click", "double_click", "right_click"].contains($0.action) }
            .map { ($0.action, $0.x, $0.y) }
    }

    // ── A 组：打字聚合与截断 ──

    func testA1TypingMergeAndReturnCut() {
        let rec = makeRec()
        feed(rec, key(4, ts: 1.0), key(14, ts: 1.1), key(37, ts: 1.2),
             key(37, ts: 1.3), key(31, ts: 1.4),          // h e l l o
             key(36, ts: 1.5))                            // return
        XCTAssertEqual(types, ["hello"])
        XCTAssertEqual(keys, ["return"])
        // A1c：type step 结构对齐宏契约（x/y nil、app、element nil）
        XCTAssertNil(steps[0].x)
        XCTAssertNil(steps[0].y)
        XCTAssertEqual(steps[0].app, "Notes")
        XCTAssertNil(steps[0].element)
    }

    func testA2BackspaceCutsAggregation() {
        let rec = makeRec()
        feed(rec, key(0, ts: 1.0), key(11, ts: 1.1), key(8, ts: 1.2),   // a b c
             key(51, ts: 1.3),                                          // delete
             key(2, ts: 1.4))                                           // d
        rec.stop()                                                      // 收尾 flush 末段打字
        XCTAssertEqual(types, ["abc", "d"])
        XCTAssertEqual(keys, ["delete"])
    }

    func testA3FocusSwitchCutsAggregation() {
        let rec = makeRec()
        feed(rec, key(0, ts: 1.0), key(11, ts: 1.1))                    // Notes: "ab"
        front = ("Safari", "com.apple.Safari", 5555)
        feed(rec, key(8, ts: 1.2), key(2, ts: 1.3))                     // "cd"
        rec.stop()
        let tsApp = steps.filter { $0.action == "type" }
            .map { ($0.payload["text"]?.string ?? "", $0.app) }
        XCTAssertEqual(tsApp.count, 2)
        XCTAssertEqual(tsApp[0].0, "ab"); XCTAssertEqual(tsApp[0].1, "Notes")
        XCTAssertEqual(tsApp[1].0, "cd"); XCTAssertEqual(tsApp[1].1, "Safari")
    }

    func testA4ClickCutsTyping() {
        let rec = makeRec()
        feed(rec, key(0, ts: 1.0), key(11, ts: 1.1),
             down(100, 200, ts: 1.2), up(100, 200, ts: 1.25))
        rec.tick(2.0)                                                   // 双击窗口过，点击定案
        XCTAssertEqual(steps.map { $0.action }, ["type", "click"])
        XCTAssertEqual(steps[0].payload["text"]?.string, "ab")
    }

    func testA5ShiftVariantAndImeText() {
        let rec = makeRec()
        feed(rec, key(0, flags: F_SHIFT, ts: 1.0),                      // A（shift 映射）
             key(18, flags: F_SHIFT, ts: 1.1),                          // !
             key(7, text: "≈", ts: 1.2))                                // IME/option 字符直达
        rec.stop()
        XCTAssertEqual(types, ["A!≈"])
    }

    func testA6OptionLetterWithoutTextSkipped() {
        let rec = makeRec()
        feed(rec, key(7, flags: F_OPT, ts: 1.0),
             key(0, ts: 1.1))
        rec.stop()
        XCTAssertEqual(types, ["a"])
    }

    // ── B 组：鼠标归并 ──

    func testB1SingleClickPendingUntilWindowExpires() {
        let rec = makeRec()
        feed(rec, down(100, 200, ts: 1.0), up(100, 200, ts: 1.1))
        XCTAssertTrue(steps.isEmpty)                                    // B1 双击窗口内未定案
        rec.tick(1.7)
        XCTAssertEqual(clicks.count, 1)
        XCTAssertEqual(clicks[0].0, "click")
        XCTAssertEqual(clicks[0].1, 100.0)
        XCTAssertEqual(clicks[0].2, 200.0)
        XCTAssertEqual(steps[0].payload["button"]?.string, "left")
        XCTAssertEqual(steps[0].payload["clicks"]?.int, 1)
    }

    func testB2SameSpotDoubleClickMerged() {
        let rec = makeRec()
        feed(rec, down(100, 200, ts: 1.0), up(100, 200, ts: 1.1),
             down(101, 201, ts: 1.2), up(101, 201, ts: 1.3))
        XCTAssertEqual(clicks.count, 1)
        XCTAssertEqual(clicks[0].0, "double_click")                     // 坐标取首次按下点
        XCTAssertEqual(clicks[0].1, 100.0)
        XCTAssertEqual(clicks[0].2, 200.0)
        XCTAssertEqual(steps[0].payload["clicks"]?.int, 2)
    }

    func testB3GapBeyondWindowYieldsTwoClicks() {
        let rec = makeRec()
        feed(rec, down(100, 200, ts: 1.0), up(100, 200, ts: 1.1),
             down(100, 200, ts: 2.0), up(100, 200, ts: 2.1))             // 间隔 0.9s 超窗
        rec.tick(3.0)
        XCTAssertEqual(clicks.map { $0.0 }, ["click", "click"])
    }

    func testB3bDistanceBeyondThresholdYieldsTwoClicks() {
        let rec = makeRec()
        feed(rec, down(100, 200, ts: 1.0), up(100, 200, ts: 1.1),
             down(140, 200, ts: 1.2), up(140, 200, ts: 1.3))             // 位移 40px 超阈
        rec.tick(3.0)
        XCTAssertEqual(clicks.map { $0.0 }, ["click", "click"])
        XCTAssertEqual(clicks[1].1, 140.0)
    }

    func testB4RightClick() {
        let rec = makeRec()
        feed(rec, down(50, 60, button: "right", ts: 1.0),
             up(50, 60, button: "right", ts: 1.1))
        rec.tick(2.0)
        XCTAssertEqual(clicks.map { $0.0 }, ["right_click"])
        XCTAssertEqual(steps[0].payload["button"]?.string, "right")
        XCTAssertEqual(steps[0].payload["clicks"]?.int, 1)
    }

    func testB5DragRecordedAsOriginClickWithDragTo() {
        let rec = makeRec()
        feed(rec, down(100, 100, ts: 1.0), up(300, 260, ts: 1.6))
        XCTAssertEqual(clicks.map { $0.0 }, ["click"])                   // 立即定案不待窗口
        XCTAssertEqual(clicks[0].1, 100.0)
        XCTAssertEqual(clicks[0].2, 100.0)
        guard case .array(let dragTo)? = steps[0].payload["drag_to"] else {
            return XCTFail("drag_to 缺失")
        }
        XCTAssertEqual(dragTo, [.double(300.0), .double(260.0)])
    }

    func testB6MiddleButtonRecordedAsClick() {
        let rec = makeRec()
        feed(rec, down(10, 10, button: "other", ts: 1.0),
             up(10, 10, button: "other", ts: 1.1))
        rec.tick(2.0)
        XCTAssertEqual(clicks.map { $0.0 }, ["click"])
        XCTAssertEqual(steps[0].payload["button"]?.string, "other")
    }

    // ── C 组：hotkey 与特殊键 ──

    func testC1ModifierCombosBecomeHotkey() {
        let rec = makeRec()
        feed(rec, key(8, flags: F_CMD, ts: 1.0),                        // cmd+c
             key(21, flags: F_CMD | F_SHIFT, ts: 1.1))                  // cmd+shift+4
        XCTAssertEqual(keys, ["cmd+c", "cmd+shift+4"])
    }

    func testC2HotkeyCutsTyping() {
        let rec = makeRec()
        feed(rec, key(0, ts: 1.0), key(8, flags: F_CMD, ts: 1.1))
        XCTAssertEqual(types, ["a"])
        XCTAssertEqual(keys, ["cmd+c"])
    }

    func testC3PureModifiersNotRecorded() {
        let rec = makeRec()
        feed(rec, key(55, ts: 1.0), key(56, ts: 1.1))
        rec.stop()
        XCTAssertTrue(steps.isEmpty)
    }

    func testC4OptionArrowKey() {
        let rec = makeRec()
        feed(rec, key(123, flags: F_OPT, ts: 1.0))
        XCTAssertEqual(keys, ["option+left"])
    }

    func testC5ShiftReturn() {
        let rec = makeRec()
        feed(rec, key(36, flags: F_SHIFT, ts: 1.0))
        XCTAssertEqual(keys, ["shift+return"])
    }

    // ── D 组：密码防护 ──

    func testD1SecureInputDropsWholeSegment() {
        secure = true
        let rec = makeRec()
        feed(rec, key(35, ts: 1.0), key(13, ts: 1.1), key(51, ts: 1.2),
             key(8, flags: F_CMD, ts: 1.3))
        XCTAssertTrue(steps.isEmpty)
        XCTAssertEqual(rec.secureDropped, 4)                            // 连长度都不记，只计数
    }

    func testD2FocusedSecureFieldDrops() {
        focused = true
        let rec = makeRec()
        feed(rec, key(35, ts: 1.0))
        XCTAssertTrue(steps.isEmpty)
        XCTAssertEqual(rec.secureDropped, 1)
    }

    func testD3PlaintextAroundSecureSegmentKeptSeparate() {
        let rec = makeRec()
        feed(rec, key(0, ts: 1.0), key(11, ts: 1.1))                    // "ab"（明文）
        secure = true
        feed(rec, key(35, ts: 1.2))                                     // 密码字符 → 丢弃
        secure = false
        feed(rec, key(8, ts: 1.3))                                      // "c"（恢复明文）
        rec.stop()
        XCTAssertEqual(types, ["ab", "c"])
    }

    // ── E 组：自身过滤 ──

    func testE1VetarAIFrontmostEventsDropped() {
        front = ("VetarAI", "com.vetarai.app", 9001)
        let rec = makeRec()
        feed(rec, key(0, ts: 1.0), down(100, 100, ts: 1.1), up(100, 100, ts: 1.2))
        rec.tick(2.0)
        XCTAssertTrue(steps.isEmpty)
    }

    func testE2SelfIdentitiesFiltered() {
        // 开发态 Electron 名 / com.vetarai* 前缀（Python E2）
        for f in [("Electron", "", Int32(9002)), ("随便什么名", "com.vetarai.dev", Int32(9003))] {
            steps = []
            front = f
            let rec = makeRec()
            feed(rec, key(0, ts: 1.0))
            rec.stop()
            XCTAssertTrue(steps.isEmpty, "\(f) 应被自过滤")
        }
        // 适配③：原生身份 ai.vetar.native（TCC 重归属后的本进程前缀）同样过滤
        steps = []
        front = ("VetarAI", "ai.vetar.native", 9004)
        let rec2 = makeRec()
        feed(rec2, key(0, ts: 1.0), down(10, 10, ts: 1.1), up(10, 10, ts: 1.2))
        rec2.tick(2.0)
        XCTAssertTrue(steps.isEmpty, "ai.vetar.* 前缀应被自过滤")
    }

    func testE3SelfSegmentCutsButDoesNotSwallow() {
        let rec = makeRec()
        feed(rec, key(0, ts: 1.0), key(11, ts: 1.1))                    // Notes 里 "ab"
        front = ("VetarAI", "com.vetarai.app", 9001)
        feed(rec, key(8, ts: 1.2))                                      // 点宏面板的按键 → 不录
        front = ("Notes", "com.apple.Notes", 4242)
        feed(rec, key(8, ts: 1.3))                                      // 回 Notes "c"
        rec.stop()
        XCTAssertEqual(types, ["ab", "c"])
    }

    func testIsSelfGates() {
        // pid == 自身进程（user_recorder.py L501-502）
        XCTAssertTrue(NativeUserRecorder.isSelf(
            name: "Whatever", bid: "", pid: ProcessInfo.processInfo.processIdentifier))
        XCTAssertTrue(NativeUserRecorder.isSelf(name: "x", bid: "ai.vetar.native", pid: 0))
        XCTAssertTrue(NativeUserRecorder.isSelf(name: "x", bid: "com.vetarai.sidecar", pid: 0))
        XCTAssertTrue(NativeUserRecorder.isSelf(name: " VetarAI ", bid: "", pid: 0))
        XCTAssertFalse(NativeUserRecorder.isSelf(name: "Notes", bid: "com.apple.Notes", pid: 4242))
        // Python startswith 前缀语义无点号边界（"com.vetarai.evil" 同滤）——宽前缀如实保留
        XCTAssertTrue(NativeUserRecorder.isSelf(name: "x", bid: "ai.vetarai.fake", pid: 0))
        XCTAssertFalse(NativeUserRecorder.isSelf(name: "x", bid: "ai.vet", pid: 0))
    }

    // ── F 组：元素语义富化 ──

    func testF1HitElementWrittenIntoStep() {
        hitStub = NativeCUElementHit(role: "AXButton", title: "存储",
                                     frame: (100.0, 200.0, 40.0, 20.0), app: "FakeApp", pid: 1)
        let rec = makeRec()
        feed(rec, down(110, 210, ts: 1.0), up(110, 210, ts: 1.1))
        rec.tick(2.0)
        XCTAssertEqual(steps.count, 1)
        let el = steps[0].element
        XCTAssertEqual(el?.role, "AXButton")
        XCTAssertEqual(el?.title, "存储")
        XCTAssertEqual(el?.frame, [100.0, 200.0, 40.0, 20.0])
        XCTAssertEqual(steps[0].app, "FakeApp")                          // hit.app 优先
    }

    func testF2MissFallsBackToCoordinatesAndFrontmostApp() {
        let rec = makeRec()                                              // hitStub=nil（未命中/异常同路径）
        feed(rec, down(33, 44, ts: 1.0), up(33, 44, ts: 1.1))
        rec.tick(2.0)
        XCTAssertEqual(steps.count, 1)
        XCTAssertNil(steps[0].element)
        XCTAssertEqual(steps[0].app, "Notes")
        XCTAssertEqual(steps[0].x, 33.0)
        XCTAssertEqual(steps[0].y, 44.0)
    }

    // ── G 组：生命周期 ──

    func testG1HardLimitTimeoutFiresOnce() {
        let rec = makeRec(maxSeconds: 600.0, withTimeout: true)
        rec.tick(1000.0 + 599.9)                                         // 未到点（t0=1000）
        XCTAssertEqual(timeoutFired, 0)
        rec.tick(1000.0 + 600.0)                                         // 到点
        rec.tick(1000.0 + 900.0)                                         // 重复 tick 不重复触发
        XCTAssertEqual(timeoutFired, 1)
    }

    func testG2StopFlushesPendingTextAndClick() {
        let rec = makeRec()
        feed(rec, key(0, ts: 1.0), key(11, ts: 1.1),
             down(100, 200, ts: 1.2), up(100, 200, ts: 1.25))
        rec.stop()
        XCTAssertEqual(steps.map { $0.action }, ["type", "click"])
        XCTAssertEqual(steps[0].payload["text"]?.string, "ab")
    }

    func testG3StopIdempotentAndSafeWithoutStart() {
        let rec = makeRec()
        feed(rec, key(0, ts: 1.0), key(11, ts: 1.1),
             down(100, 200, ts: 1.2), up(100, 200, ts: 1.25))
        rec.stop()
        rec.stop()                                                       // 幂等：不重复 flush
        XCTAssertEqual(steps.map { $0.action }, ["type", "click"])
        steps = []
        let rec2 = makeRec()
        rec2.stop()                                                      // 空录制 stop 安全
        XCTAssertTrue(steps.isEmpty)
    }

    // ── 协议常量锚（Python L59-67 逐字）──

    func testProtocolConstants() {
        XCTAssertEqual(NativeUserRecorder.doubleClickMaxGap, 0.5)
        XCTAssertEqual(NativeUserRecorder.doubleClickMaxDist, 5.0)
        XCTAssertEqual(NativeUserRecorder.dragMinDist, 8.0)
        XCTAssertEqual(NativeUserRecorder.tickInterval, 0.25)
        XCTAssertEqual(NativeUserRecorder.tapStartTimeout, 3.0)
        XCTAssertEqual(NativeUserRecorder.joinTimeout, 2.0)
        XCTAssertEqual(NativeUserRecorder.titleMax, 80)
        XCTAssertEqual(NativeUserRecorder.roleMax, 40)
        XCTAssertEqual(NativeUserRecorder.flagShift, 1 << 17)
        XCTAssertEqual(NativeUserRecorder.flagCtrl, 1 << 18)
        XCTAssertEqual(NativeUserRecorder.flagOpt, 1 << 19)
        XCTAssertEqual(NativeUserRecorder.flagCmd, 1 << 20)
    }

    /// pyRound1：Python round(x,1) 二进制真值半进偶（回放/落盘坐标契约；
    /// 真值经 CPython 实算核对：0.35→0.3 / 0.45→0.5）。
    func testPyRound1HalfEven() {
        XCTAssertEqual(NativeUserRecorder.pyRound1(100.0), 100.0)
        XCTAssertEqual(NativeUserRecorder.pyRound1(300.0), 300.0)
        XCTAssertEqual(NativeUserRecorder.pyRound1(0.25), 0.2)
        XCTAssertEqual(NativeUserRecorder.pyRound1(0.35), 0.3, accuracy: 1e-9)
        XCTAssertEqual(NativeUserRecorder.pyRound1(0.45), 0.5, accuracy: 1e-9)
        XCTAssertEqual(NativeUserRecorder.pyRound1(123.456), 123.5, accuracy: 1e-9)
    }

    // ══════════════════════════════════════════════════════════
    // R 组（Bug6，2026-09-28）：requestListenAccessFlow 纯决策核钉桩——
    // CU 宏「请求授权」按钮点击静默无反应的回归防线。
    // ⛔ 真实 TCC 弹窗 / 名单登记 / probeListenTapAttempt 真 tap 属真机行为，
    // 无法单测（与文件头纪律同款）；真机验证步骤见提交说明。此处只钉
    // 决策核的分支、短路与调用序（系统调用全注入假闭包）。
    // ══════════════════════════════════════════════════════════

    /// R1：preflight 已授权 → 幂等短路直返 true（不建探测 tap、不调请求 API——
    /// 避免多余系统调用与弹窗疲劳）。
    func testR1RequestFlowAlreadyGrantedShortCircuits() {
        var calls: [String] = []
        let r = NativeUserRecorder.requestListenAccessFlow(
            preflight: { calls.append("preflight"); return true },
            probeTap: { calls.append("probe"); return false },
            request: { calls.append("request"); return false })
        XCTAssertTrue(r)
        XCTAssertEqual(calls, ["preflight"], "已授权不得再触探测 tap / 请求 API")
    }

    /// R2：preflight 未授权但探测 tap 建成（preflight 与 tap 判定竞态）→
    /// 直返 true，不调请求 API。
    func testR2RequestFlowProbeTapGrantedShortCircuits() {
        var calls: [String] = []
        let r = NativeUserRecorder.requestListenAccessFlow(
            preflight: { calls.append("preflight"); return false },
            probeTap: { calls.append("probe"); return true },
            request: { calls.append("request"); return false })
        XCTAssertTrue(r)
        XCTAssertEqual(calls, ["preflight", "probe"])
    }

    /// R3：核心修复路径——preflight 未授权 → 先探测 tap（TCC 登记 listen-event
    /// 需求）→ 再调系统请求 API → preflight 复核为准（复核 granted → true）；
    /// 调用序必须完整，探测登记必须先于请求。
    func testR3RequestFlowProbeThenRequestThenRecheckGranted() {
        var calls: [String] = []
        var preflightResults: [Bool?] = [false, true]      // 首查未授权 → 复核已授权
        let r = NativeUserRecorder.requestListenAccessFlow(
            preflight: { calls.append("preflight"); return preflightResults.removeFirst() },
            probeTap: { calls.append("probe"); return false },
            request: { calls.append("request"); return true })
        XCTAssertTrue(r)
        XCTAssertEqual(calls, ["preflight", "probe", "request", "preflight"],
                       "探测登记必须先于请求 API——未登记进程的请求静默无反应（Bug6）")
        XCTAssertTrue(preflightResults.isEmpty, "复核必须真实发生一次")
    }

    /// R3b：复核仍 denied → false（request 返回值不得盖过 preflight 复核，
    /// Python L243-245 口径；Bug6 生产形态：请求已发但系统未弹/用户未点）。
    func testR3bRequestFlowRecheckDeniedStaysDenied() {
        var calls: [String] = []
        let r = NativeUserRecorder.requestListenAccessFlow(
            preflight: { calls.append("preflight"); return false },
            probeTap: { calls.append("probe"); return false },
            request: { calls.append("request"); return true })
        XCTAssertFalse(r)
        XCTAssertEqual(calls, ["preflight", "probe", "request", "preflight"])
    }

    /// R4：复核探测不到（nil）→ 回落请求 API 返回值（true/false 两向钉桩）；
    /// 首查 nil 同样不得短路（探测 tap 与请求照常走）。
    func testR4RequestFlowRecheckUnknownFallsBackToRequest() {
        var preflightResults: [Bool?] = [false, nil]
        let granted = NativeUserRecorder.requestListenAccessFlow(
            preflight: { preflightResults.removeFirst() },
            probeTap: { false },
            request: { true })
        XCTAssertTrue(granted, "复核 nil → 回落 request 返回值")
        XCTAssertTrue(preflightResults.isEmpty)

        var preflightResults2: [Bool?] = [nil, nil]
        let denied = NativeUserRecorder.requestListenAccessFlow(
            preflight: { preflightResults2.removeFirst() },
            probeTap: { false },
            request: { false })
        XCTAssertFalse(denied)
        XCTAssertTrue(preflightResults2.isEmpty,
                      "首查 nil ≠ 已授权，不得短路跳过探测与请求")
    }
}
