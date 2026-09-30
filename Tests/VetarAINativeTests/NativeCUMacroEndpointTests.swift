//
//  NativeCUMacroEndpointTests.swift
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

//  逐条翻译 subagent/sidecar/computer_use/test_cu_user_record.py H 组（端点契约 1-6）
//  + test_cu_macro.py I 组（端点 HTTP 语义；⛔ 只读行为规格源，语义以 Python 为准）：
//    · H1 权限两端点：bool(g)（None→false）/ request 返回弹窗后状态
//    · H2 user 未授权 → 403 detail 前缀 + 中文指引（含二进制路径与 Cmd+Q 文案）；
//      探测不到（nil）不拦截（Python `is False` 判定——None 放行）
//    · H3 缺省 mode=agent 零变化：agent+agent 422 / 涉 user 409 / 非法 mode 422
//    · H4 user start → recording_mode=user + maxSeconds 来自 config + 409 互斥
//    · H5 user 录制中回放 → 409 user_recording_busy
//    · H6 有步 stop → saved:true 落盘 + capture.stop 被调 + flush 收尾步骤落宏
//      （顺序铁律：先拆捕获再清录制单例）+ A13 create 事件
//    · H7 空转 stop → 200 saved:false 契约逐字 + 捕获同样拆除
//    · H8 超时自动停（硬上限到点视作正常 stop，有步落盘）
//    · H9 回放链路：404 not_found / 422 empty_macro / done 轮询 / replays 404 /
//      replay_step 六字段事件
//    · H10 回放进行中 user start → 409 replay_busy（真实键鼠独占）
//    · H11 delete：404 非法/缺失 → ok + A13 delete
//    · H12 capture_failed（工厂 nil）→ 422 逐字
//
//  ⛔ 零真实 TCC/键鼠：权限探针/捕获工厂/回放执行面全注入假件；
//  真 CGEventTap/系统弹窗属真机冒烟（父代理）。
//

import XCTest
@testable import VetarAINative

final class NativeCUMacroEndpointTests: XCTestCase {

    // ── 假捕获（test_cu_user_record._FakeCapture 同构 + flush 收尾模拟）──
    private final class FakeCapture: NativeUserCaptureSession, @unchecked Sendable {
        var stopped = false
        var onStep: (@Sendable (NativeUserRecorder.Step) -> Void)?
        var onTimeout: (@Sendable () -> Void)?
        var flushStep: NativeUserRecorder.Step?
        func stop() {
            stopped = true
            if let s = flushStep { onStep?(s) }   // tap 线程 flush 的最终聚合步骤
        }
    }

    private var tmp: URL!
    private var store: NativeCUMacroStore!
    private var endpoints: NativeCUMacroEndpoints!
    private var listenGranted: Bool? = false
    private var requestResult = false
    private var maxSeconds: Double = 600
    private var factoryCalls: [Double] = []
    private var factoryProduct: FakeCapture?
    private var factoryReturnsNil = false
    private var stepEvents: [(runId: String, macroId: String, seq: Int,
                              action: String, method: String, ok: Bool)] = []
    // 回放执行面桩
    private var execOK = true
    private var blockClicks: DispatchSemaphore?
    private var clickedXY: [(Double, Double)] = []

    override func setUp() {
        super.setUp()
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("p3w4_ep_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        store = NativeCUMacroStore(dataRoot: tmp, sleeper: { _ in })
        endpoints = NativeCUMacroEndpoints(store: store)
        listenGranted = false
        requestResult = false
        maxSeconds = 600
        factoryCalls = []
        factoryProduct = nil
        factoryReturnsNil = false
        stepEvents = []
        execOK = true
        blockClicks = nil
        clickedXY = []

        endpoints.listenAccessGranted = { [self] in self.listenGranted }
        endpoints.requestListenAccess = { [self] in self.requestResult }
        store.listenAccessGrantedProvider = { [self] in self.listenGranted }
        store.maxSecondsProvider = { [self] in self.maxSeconds }
        store.processExeProvider = { "/Applications/VetarAI.app/Contents/MacOS/VetarAI" }
        store.userCaptureFactory = { [self] onStep, onTimeout, maxS in
            self.factoryCalls.append(maxS)
            if self.factoryReturnsNil { return nil }
            let cap = FakeCapture()
            cap.onStep = onStep
            cap.onTimeout = onTimeout
            self.factoryProduct = cap
            return cap
        }
        store.replayStepEventPusher = { [self] runId, macroId, seq, action, method, ok in
            self.stepEvents.append((runId, macroId, seq, action, method, ok))
        }
        store.clickExecutor = { [self] x, y, _, _ in
            self.blockClicks?.wait()
            self.clickedXY.append((x, y))
            return self.execOK ? ["ok": .bool(true)]
                : ["ok": .bool(false), "error": .string("stub_click_failed")]
        }
        store.typeExecutor = { [self] _ in
            return self.execOK ? ["ok": .bool(true)]
                : ["ok": .bool(false), "error": .string("stub_type_failed")]
        }
        store.hotkeyExecutor = { [self] _ in
            return self.execOK ? ["ok": .bool(true)]
                : ["ok": .bool(false), "error": .string("stub_key_failed")]
        }
        store.elementsProvider = { _, _ in [] }        // 枚举失败 → 像素回落
        store.axLastErrorProvider = { "" }
    }

    override func tearDown() {
        blockClicks?.signal()
        if let tmp { try? FileManager.default.removeItem(at: tmp) }
        super.tearDown()
    }

    // ── 助手 ──

    private func assertHTTP(_ status: Int, _ prefix: String = "",
                            file: StaticString = #filePath, line: UInt = #line,
                            _ work: () throws -> Any) -> String {
        do {
            _ = try work()
            XCTFail("应抛 \(status)", file: file, line: line)
            return ""
        } catch SidecarError.httpError(let s, let detail) {
            XCTAssertEqual(s, status, "detail=\(detail)", file: file, line: line)
            if !prefix.isEmpty {
                XCTAssertTrue(detail.hasPrefix(prefix), "detail=\(detail)",
                              file: file, line: line)
            }
            return detail
        } catch {
            XCTFail("错误类型不符: \(error)", file: file, line: line)
            return ""
        }
    }

    /// 造一个含一步像素点击的宏文件（回放链路用）。
    @discardableResult
    private func saveClickMacro(id: String = "cu-test-macro-0001",
                                steps: [[String: JSONValue]]? = nil) -> [String: JSONValue] {
        let defaultSteps: [[String: JSONValue]] = [[
            "seq": .int(1), "action": .string("click"),
            "x": .double(10), "y": .double(20), "app": .string(""),
            "element": .null, "payload": .object(["button": .string("left"),
                                                  "clicks": .int(1)]),
            "ts": .string("2026-09-21T10:00:00"),
        ]]
        let macro: [String: JSONValue] = [
            "id": .string(id), "name": .string("测试宏"),
            "created_at": .string("2026-09-21T10:00:00"),
            "steps": .array((steps ?? defaultSteps).map { .object($0) }),
        ]
        try! store.saveMacro(macro)
        return macro
    }

    private func waitRunTerminal(_ runId: String) -> NativeCUMacroStore.ReplayRun? {
        let deadline = Date().addingTimeInterval(3)
        var run = store.getRun(runId)
        while run?.status == "running", Date() < deadline {
            Thread.sleep(forTimeInterval: 0.005)
            run = store.getRun(runId)
        }
        return run
    }

    private func typeStep(_ text: String) -> NativeUserRecorder.Step {
        NativeUserRecorder.Step(action: "type", x: nil, y: nil, app: "Notes",
                                element: nil, payload: ["text": .string(text)])
    }

    // MARK: - H1 权限两端点

    func testH1PermissionBoolMapping() {
        listenGranted = false
        XCTAssertFalse(endpoints.userRecordPermission().granted)
        listenGranted = nil                                   // 探测不到 → bool(None)=false
        XCTAssertFalse(endpoints.userRecordPermission().granted)
        listenGranted = true
        XCTAssertTrue(endpoints.userRecordPermission().granted)
    }

    func testH1bPermissionRequest() {
        requestResult = false
        XCTAssertFalse(endpoints.requestUserRecordPermission().granted)
        requestResult = true
        XCTAssertTrue(endpoints.requestUserRecordPermission().granted)
    }

    // MARK: - H2 user 未授权守卫

    func testH2UserStartDenied403() throws {
        listenGranted = false
        let detail = assertHTTP(403, "input_monitoring_not_granted") {
            try endpoints.recordStart(name: "宏", mode: "user")
        }
        // 中文授权指引逐字段（_input_monitoring_error L199-215；二进制路径 = 注入的本进程路径）
        XCTAssertTrue(detail.contains("系统设置→隐私与安全性→输入监控"), detail)
        XCTAssertTrue(detail.contains("它与「辅助功能」是两项独立授权"), detail)
        XCTAssertTrue(detail.contains(
            "请把这个文件本身加入名单：\n    /Applications/VetarAI.app/Contents/MacOS/VetarAI\n"), detail)
        XCTAssertTrue(detail.contains("完全退出 VetarAI（Cmd+Q）后重开（权限在进程启动时读取）"), detail)
        // 未进入录制 + 捕获工厂未被调
        XCTAssertFalse(endpoints.list().recording)
        XCTAssertNil(endpoints.list().recordingMode)
        XCTAssertTrue(factoryCalls.isEmpty)
    }

    func testH2bPermissionUnknownPasses() throws {
        listenGranted = nil          // Python `is False` 判定：None（探测不到）不拦截
        let name = try endpoints.recordStart(name: "宏", mode: "user")
        XCTAssertEqual(name, "宏")
        XCTAssertEqual(factoryCalls.count, 1)
        XCTAssertEqual(endpoints.list().recordingMode, "user")
        _ = try endpoints.recordStop()
    }

    // MARK: - H3 缺省 agent 零变化 + mode 校验

    func testH3AgentDefaultAndConflicts() throws {
        let name = try endpoints.recordStart(name: "  宏A  ", mode: nil)
        XCTAssertEqual(name, "宏A")                                  // strip + 服务端名为准
        XCTAssertEqual(endpoints.list().recordingMode, "agent")
        // agent+agent 重复开始 → 422（conflict=false，现状零变化）
        let d1 = assertHTTP(422, "already_recording: 正在录制宏「宏A」（agent 模式）") {
            try endpoints.recordStart(name: "宏B", mode: nil)
        }
        XCTAssertTrue(d1.contains("请先停止当前录制"))
        // agent 录制中 user start → 409（契约6 跨模式互斥）
        listenGranted = true
        assertHTTP(409, "already_recording: 正在录制宏「宏A」（agent 模式）") {
            try endpoints.recordStart(name: "宏B", mode: "user")
        }
        _ = try endpoints.recordStop()
    }

    func testH3eBadModeAndEmptyName() {
        listenGranted = true
        let d = assertHTTP(422, "bad_arg: mode 只能是 agent/user") {
            try endpoints.recordStart(name: "宏", mode: "bogus")
        }
        XCTAssertTrue(d.contains("（收到 'bogus'）"), d)
        assertHTTP(422, "bad_arg: 宏名称不能为空") {
            try endpoints.recordStart(name: "   ", mode: nil)
        }
    }

    // MARK: - H4 user start 契约

    func testH4UserStartOk() throws {
        listenGranted = true
        maxSeconds = 120
        let name = try endpoints.recordStart(name: "用户宏", mode: "user")
        XCTAssertEqual(name, "用户宏")
        XCTAssertEqual(factoryCalls.count, 1)
        XCTAssertEqual(factoryCalls[0], 120)                // max_seconds 来自 config
        XCTAssertEqual(endpoints.list().recordingMode, "user")
        XCTAssertTrue(endpoints.list().recording)
        XCTAssertEqual(endpoints.list().recordingSteps, 0)
        // user 录制中 user start → 409 already_recording
        assertHTTP(409, "already_recording: 正在录制宏「用户宏」（user 模式）") {
            try endpoints.recordStart(name: "再录", mode: "user")
        }
        // user 录制中 agent start → 409（cur=user → conflict=true）
        assertHTTP(409, "already_recording: 正在录制宏「用户宏」（user 模式）") {
            try endpoints.recordStart(name: "再录", mode: nil)
        }
        _ = try endpoints.recordStop()
    }

    func testH4MaxSecondsFalsyDefaults600() throws {
        listenGranted = true
        maxSeconds = 0                                                 // Python `or 600` 口径
        _ = try endpoints.recordStart(name: "宏", mode: "user")
        XCTAssertEqual(factoryCalls[0], 600)
        _ = try endpoints.recordStop()
    }

    // MARK: - H5 user 录制中回放互斥

    func testH5ReplayDeniedWhileUserRecording() throws {
        saveClickMacro()
        listenGranted = true
        _ = try endpoints.recordStart(name: "用户宏", mode: "user")
        let detail = assertHTTP(409, "user_recording_busy") {
            try endpoints.replay(macroId: "cu-test-macro-0001")
        }
        XCTAssertTrue(detail.contains("请先停止录制再回放"), detail)
        _ = try endpoints.recordStop()
    }

    // MARK: - H6 有步 stop（落盘 + 捕获拆除 + flush 收尾 + A13）

    func testH6UserStopWithStepsSaves() async throws {
        listenGranted = true
        NativeAppEvents.clearAll()
        _ = try endpoints.recordStart(name: "用户宏", mode: "user")
        let cap = try XCTUnwrap(factoryProduct)
        cap.onStep?(typeStep("hello"))                                 // tap 归并出的 step
        XCTAssertEqual(endpoints.list().recordingSteps, 1)
        cap.flushStep = typeStep("!")                                  // stop 时 tap 线程 flush 收尾
        let r = try endpoints.recordStop()
        XCTAssertTrue(r.saved)
        XCTAssertTrue(cap.stopped)                                     // 捕获被拆除
        XCTAssertFalse(endpoints.list().recording)
        XCTAssertNil(endpoints.list().recordingMode)
        // 落盘宏含两个 step（flush 收尾步骤在 rec 清空前受理——顺序铁律）
        let macros = endpoints.list().macros
        XCTAssertEqual(macros.count, 1)
        XCTAssertEqual(macros[0].name, "用户宏")
        XCTAssertEqual(macros[0].steps, 2)
        let loaded = store.loadMacro(macros[0].id)
        guard case .array(let steps)? = loaded?["steps"] else {
            return XCTFail("宏文件 steps 缺失")
        }
        XCTAssertEqual(steps.count, 2)
        XCTAssertEqual(steps[0].object?["payload"]?.object?["text"]?.string, "hello")
        XCTAssertEqual(steps[1].object?["payload"]?.object?["text"]?.string, "!")
        XCTAssertEqual(steps[0].object?["seq"]?.int, 1)
        XCTAssertEqual(steps[1].object?["seq"]?.int, 2)
        // A13 create 事件（resource=cu_macro, action=create, macro_id）
        let events = NativeAppEvents.subscribe(sinceSeq: 0, idleTimeout: 0.05)
        var saw: [String: JSONValue]?
        for await ev in events where ev.event == "resource_changed" {
            if ev.data["resource"]?.string == "cu_macro" {
                saw = ev.data
                break
            }
        }
        XCTAssertEqual(saw?["action"]?.string, "create")
        XCTAssertEqual(saw?["macro_id"]?.string, macros[0].id)
    }

    // MARK: - H7 空转 stop（0 步契约）

    func testH7UserStopEmptyContract() throws {
        listenGranted = true
        _ = try endpoints.recordStart(name: "空宏", mode: "user")
        let r = try endpoints.recordStop()
        XCTAssertFalse(r.saved)
        XCTAssertEqual(r.steps, 0)
        XCTAssertEqual(r.message, "未捕获到任何动作，宏未保存")
        XCTAssertTrue(factoryProduct?.stopped ?? false)                // 空转 stop 也拆捕获
        XCTAssertTrue(endpoints.list().macros.isEmpty)                 // 不落盘
        XCTAssertFalse(endpoints.list().recording)
    }

    func testH8StopWithoutRecording422() {
        assertHTTP(422, "not_recording: 当前没有进行中的录制") {
            try endpoints.recordStop()
        }
    }

    // MARK: - H8b 超时自动停（硬上限视作正常 stop）

    func testH8bTimeoutAutoStopSaves() throws {
        listenGranted = true
        _ = try endpoints.recordStart(name: "超时宏", mode: "user")
        let cap = try XCTUnwrap(factoryProduct)
        cap.onStep?(typeStep("x"))
        cap.onTimeout?()                                               // ticker 硬上限到点
        XCTAssertFalse(endpoints.list().recording)
        XCTAssertTrue(cap.stopped)
        let macros = endpoints.list().macros
        XCTAssertEqual(macros.count, 1)
        XCTAssertEqual(macros[0].steps, 1)
    }

    // MARK: - H9 回放链路（404/422/done/事件）

    func testH9ReplayNotFoundAndEmptyAndDone() throws {
        assertHTTP(404, "宏不存在或已删除") {
            try endpoints.replay(macroId: "../../etc")                 // 非法 id
        }
        assertHTTP(404, "宏不存在或已删除") {
            try endpoints.replay(macroId: "cu-missing-0001")           // 合法 id 但文件缺失
        }
        saveClickMacro(id: "cu-empty-0001", steps: [])
        assertHTTP(422, "empty_macro: 宏没有可回放的步骤") {
            try endpoints.replay(macroId: "cu-empty-0001")
        }
        // 正常回放：像素回落（elementsProvider 空）→ done
        saveClickMacro(id: "cu-ok-0001")
        let runId = try endpoints.replay(macroId: "cu-ok-0001")
        XCTAssertTrue(runId.hasPrefix("run-"))
        let run = try XCTUnwrap(waitRunTerminal(runId))
        XCTAssertEqual(run.status, "done")
        XCTAssertEqual(run.completed, 1)
        XCTAssertEqual(clickedXY.count, 1)
        // 轮询端点语义（steps 明细 + 字段映射）
        let polled = try endpoints.replayStatus(runId: runId)
        XCTAssertEqual(polled.status, "done")
        XCTAssertEqual(polled.macro_id, "cu-ok-0001")
        XCTAssertEqual(polled.macro_name, "测试宏")
        XCTAssertEqual(polled.total, 1)
        XCTAssertEqual(polled.completed, 1)
        XCTAssertNil(polled.failed_seq)
        XCTAssertEqual(polled.steps.count, 1)
        XCTAssertEqual(polled.steps[0].seq, 1)
        XCTAssertEqual(polled.steps[0].action, "click")
        XCTAssertEqual(polled.steps[0].method, "pixel_fallback")
        XCTAssertTrue(polled.steps[0].ok)
        // replay_step 六字段事件（_push_step_event 契约）
        XCTAssertEqual(stepEvents.count, 1)
        XCTAssertEqual(stepEvents[0].runId, runId)
        XCTAssertEqual(stepEvents[0].macroId, "cu-ok-0001")
        XCTAssertEqual(stepEvents[0].seq, 1)
        XCTAssertEqual(stepEvents[0].action, "click")
        XCTAssertEqual(stepEvents[0].method, "pixel_fallback")
        XCTAssertTrue(stepEvents[0].ok)
    }

    func testH9bReplayStatus404() {
        assertHTTP(404, "回放记录不存在") {
            try endpoints.replayStatus(runId: "run-nonexistent")
        }
    }

    // MARK: - H10 回放进行中 user start → 409 replay_busy

    func testH10UserStartDeniedWhileReplayBusy() throws {
        listenGranted = true
        blockClicks = DispatchSemaphore(value: 0)
        saveClickMacro(id: "cu-busy-0001")
        let runId = try endpoints.replay(macroId: "cu-busy-0001")
        // 等回放进入执行（busy 已置位：start_replay 登记即 busy）
        let detail = assertHTTP(409, "replay_busy: 已有回放进行中") {
            try endpoints.recordStart(name: "宏", mode: "user")
        }
        XCTAssertTrue(detail.contains("请等当前回放完成再开始录制"), detail)
        XCTAssertTrue(factoryCalls.isEmpty)                            // 未建捕获
        blockClicks?.signal()
        blockClicks = nil
        XCTAssertEqual(waitRunTerminal(runId)?.status, "done")
    }

    // MARK: - H11 delete

    func testH11Delete() async throws {
        assertHTTP(404, "宏不存在或已删除") {
            try endpoints.deleteMacro(macroId: "../x")
        }
        assertHTTP(404, "宏不存在或已删除") {
            try endpoints.deleteMacro(macroId: "cu-missing-0001")
        }
        saveClickMacro(id: "cu-del-0001")
        NativeAppEvents.clearAll()
        try endpoints.deleteMacro(macroId: "cu-del-0001")
        XCTAssertTrue(endpoints.list().macros.isEmpty)
        let events = NativeAppEvents.subscribe(sinceSeq: 0, idleTimeout: 0.05)
        var saw: [String: JSONValue]?
        for await ev in events where ev.event == "resource_changed" {
            if ev.data["resource"]?.string == "cu_macro" {
                saw = ev.data
                break
            }
        }
        XCTAssertEqual(saw?["action"]?.string, "delete")
        XCTAssertEqual(saw?["macro_id"]?.string, "cu-del-0001")
        // 已删宏回放 → 404
        assertHTTP(404, "宏不存在或已删除") {
            try endpoints.replay(macroId: "cu-del-0001")
        }
    }

    // MARK: - H12 capture_failed

    func testH12CaptureFailed422() {
        listenGranted = true
        factoryReturnsNil = true
        let detail = assertHTTP(422, "capture_failed: 系统级捕获启动失败") {
            try endpoints.recordStart(name: "宏", mode: "user")
        }
        XCTAssertTrue(detail.contains("请确认「输入监控」已授予且没有其他录制在进行"), detail)
        XCTAssertFalse(endpoints.list().recording)
    }

    // MARK: - 宏名截断契约（TITLE_MAX=80，start_recording L268）

    func testRecordStartNameTruncated80() throws {
        let long = String(repeating: "宏", count: 100)
        let name = try endpoints.recordStart(name: long, mode: nil)
        XCTAssertEqual(name.count, 80)
        _ = try endpoints.recordStop()
    }
}
