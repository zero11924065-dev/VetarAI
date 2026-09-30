//
//  NativeCUMacroTests.swift
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

//  逐条翻译 subagent/sidecar/computer_use/test_cu_macro.py 与
//  test_cu_macro_agent.py（⛔ 只读行为规格源；语义以 Python 源码为准）：
//    · A 组 存储：tmp+rename 原子写 / 摘要列表排序 / 损坏文件跳过 / id 防路径穿越
//    · B 组 录制器：单例 / seq 自增 / step 八字段 / title≤80 role≤40 截断
//    · K 组 空宏防护（0.4.33 F2）：0 步不落盘、契约逐字、0 步宏拒绝回放
//    · C 组 executor 录制挂钩：命中点击落语义 step（frame 中心、不重复 hit_test）、
//      失败动作不落宏、未录制零开销
//    · D/E/F/G 组 回放：语义重定位（title 必须参与匹配）/ 像素回落 / R4 中止
//      （app 未运行报步骤号，后续步骤绝不执行）/ type-key payload 重放
//    · AG-B/C/D 组 工具层契约：record start/stop 透传 / replay id-name 解析
//      （ambiguous 拒绝猜测）/ 整宏一次确认 / list 摘要字段
//
//  ⛔ 零真实键鼠：回放执行面（clickExecutor/typeExecutor/hotkeyExecutor）与
//  appElements 枚举全部注入记录型桩；真 CG 层仅编译链接验证。
//
//  ⚠️VERIFY 未翻（原因列于汇报）：
//    · test_cu_macro_agent.py A/E 组（tools_spec 暴露与系统提示词 CU 段）——W4a 路由/
//      提示词装配层，属既有基线覆盖范围。
//
//  P3-W4 已闭环（原 W4c ⚠️VERIFY 项）：
//    · test_cu_macro.py H 组 replay_step 事件推送 → NativeCUMacroStore
//      replayStepEventPusher 接原生总线（NativeCUMacroEndpointTests H9 六字段断言）。
//    · test_cu_macro.py I 组端点 HTTP 语义（422/404）→ NativeCUMacroEndpoints
//      端点面翻原生（NativeCUMacroEndpointTests 逐状态码断言）。
//    · test_cu_macro.py A4 delete_macro → store.deleteMacro + DELETE 端点（H11）。
//    · user_recorder 系统级录制（0.4.34 R4，CGEventTap）→ NativeUserRecorder.swift
//      全量移植（NativeUserRecorderTests A~G 组对拍 + 端点 H 组契约）。
//

import XCTest
@testable import VetarAINative

final class NativeCUMacroTests: XCTestCase {

    private var tmp: URL!
    private var store: NativeCUMacroStore!
    // 回放捕获桩（_CapExec 同构）
    private var clicks: [(x: Double, y: Double, button: String, clicks: Int)] = []
    private var types: [String] = []
    private var keys: [String] = []
    private var execOK = true
    private var stubElements: [NativeCUElementHit] = []
    private var stubLastError = ""
    private var enumCalls: [(app: String, depth: Int)] = []

    override func setUp() {
        super.setUp()
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("p2w4c_macro_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        store = NativeCUMacroStore(dataRoot: tmp, sleeper: { _ in })
        clicks = []; types = []; keys = []; execOK = true
        stubElements = []; stubLastError = ""; enumCalls = []
        wireExecutors(store)
    }

    override func tearDown() {
        if let tmp { try? FileManager.default.removeItem(at: tmp) }
        super.tearDown()
    }

    /// _patch_replay 同构：执行面三动作→捕获桩；appElements→固定元素列表。
    private func wireExecutors(_ s: NativeCUMacroStore) {
        s.clickExecutor = { [self] x, y, btn, n in
            self.clicks.append((x, y, btn, n))
            return self.execOK ? ["ok": .bool(true)]
                : ["ok": .bool(false), "error": .string("stub_click_failed")]
        }
        s.typeExecutor = { [self] text in
            self.types.append(text)
            return self.execOK ? ["ok": .bool(true)]
                : ["ok": .bool(false), "error": .string("stub_type_failed")]
        }
        s.hotkeyExecutor = { [self] k in
            self.keys.append(k)
            return self.execOK ? ["ok": .bool(true)]
                : ["ok": .bool(false), "error": .string("stub_key_failed")]
        }
        s.elementsProvider = { [self] app, depth in
            self.enumCalls.append((app, depth)); return self.stubElements
        }
        s.axLastErrorProvider = { [self] in self.stubLastError }
    }

    // ── 构造助手（_macro/_click_step 同构）──
    private func macro(_ id: String, name: String = "测试宏",
                       steps: [[String: JSONValue]] = [],
                       created: String = "2026-09-18T12:00:00") -> [String: JSONValue] {
        ["id": .string(id), "name": .string(name),
         "created_at": .string(created), "steps": .array(steps.map { .object($0) })]
    }

    private func clickStep(_ seq: Int, x: Double = 10, y: Double = 10,
                           app: String = "FakeApp",
                           element: [String: JSONValue]?? = nil,
                           action: String = "click") -> [String: JSONValue] {
        let el: JSONValue
        if let element {
            el = element.map { .object($0) } ?? .null
        } else {
            el = .object(["role": .string("AXButton"), "title": .string("删除"),
                          "frame": .array([100.0, 200.0, 40.0, 20.0].map { .double($0) })])
        }
        return ["seq": .int(Int64(seq)), "action": .string(action),
                "x": .double(x), "y": .double(y), "app": .string(app),
                "element": el, "payload": .object([:]),
                "ts": .string("2026-09-18T12:00:01")]
    }

    /// start_replay 后轮询至终态（sleeper 已置 0，回放微秒级）。
    private func waitRun(_ runId: String, timeout: UInt64 = 3_000_000_000) -> NativeCUMacroStore.ReplayRun? {
        let deadline = Date().addingTimeInterval(Double(timeout) / 1_000_000_000)
        var run = store.getRun(runId)
        while run?.status == "running", Date() < deadline {
            Thread.sleep(forTimeInterval: 0.005)
            run = store.getRun(runId)
        }
        return run
    }

    // ══════════════════════════════════════════════════════════
    // MARK: A 组 存储（test_a_storage）
    // ══════════════════════════════════════════════════════════

    /// A1/A1b/A3/A3b/A5：落盘路径 / 读回一致 / 摘要排序与字段 / 损坏跳过
    func testA_storageRoundtripAndList() throws {
        let m1 = macro("cu-20260918-120000-test-a1b2", steps: [clickStep(1)])
        try store.saveMacro(m1)
        let path = tmp.appendingPathComponent("cu_macros/cu-20260918-120000-test-a1b2.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path), "A1 落盘路径正确")
        let back = store.loadMacro("cu-20260918-120000-test-a1b2")
        XCTAssertEqual(back?["name"]?.string, "测试宏", "A1b 读回字段一致")
        XCTAssertEqual(back?["steps"]?.array?.count, 1)
        XCTAssertEqual(back?["steps"]?.array?[0].object?["element"]?.object?["title"]?.string,
                       "删除")
        // A3：列表按 (created_at, id) 升序；摘要仅四字段、steps 为数
        try store.saveMacro(macro("cu-20260918-120002-test-e5f6", name: "丙",
                                  created: "2026-09-18T11:00:00"))
        let lst = store.listMacros()
        XCTAssertEqual(lst.count, 2)
        XCTAssertTrue(lst[0].id.hasSuffix("e5f6"), "A3 created_at 升序")
        XCTAssertEqual(lst[0].steps, 0, "A3b steps 为数不是全量")
        XCTAssertEqual(lst.first { $0.id == "cu-20260918-120000-test-a1b2" }?.steps, 1)
        // A5：损坏 JSON → 列表跳过且 load→nil（不阻断其他宏）
        let bad = tmp.appendingPathComponent("cu_macros/cu-20260918-130000-broken-z9y8.json")
        try "{半截".write(to: bad, atomically: false, encoding: .utf8)
        XCTAssertNil(store.loadMacro("cu-20260918-130000-broken-z9y8"), "A5 损坏 load→nil")
        XCTAssertEqual(store.listMacros().count, 2, "A5 损坏文件列表跳过")
    }

    /// A2：原子写——tmp 写失败 → 抛出且旧文件完好（写一半被 kill 不得留半截）
    func testA_atomicWriteFailureKeepsOldFile() throws {
        let mid = "cu-20260918-120001-test-c3d4"
        try store.saveMacro(macro(mid, name: "乙"))
        let path = tmp.appendingPathComponent("cu_macros/\(mid).json")
        let good = try String(contentsOf: path, encoding: .utf8)
        // 置 tmp 路径为目录 → data.write 必抛（模拟写一半被 kill）
        let tmpFile = tmp.appendingPathComponent("cu_macros/\(mid).json.tmp")
        try FileManager.default.createDirectory(at: tmpFile, withIntermediateDirectories: true)
        XCTAssertThrowsError(try store.saveMacro(macro(mid, name: "乙改")),
                             "A2 写失败必须抛出（绝不静默丢宏）")
        XCTAssertEqual(try String(contentsOf: path, encoding: .utf8), good,
                       "A2 旧文件完好")
    }

    /// A4c：非法 id → valid=false 且 load 安全返回 nil（URL 来的 id 不可信）
    func testA_pathTraversalDefense() {
        for bad in ["../etc", "..%2F..%2Fetc", "a/b", "", "x.json",
                    String(repeating: "a", count: 200)] {
            XCTAssertFalse(NativeCUMacroStore.validMacroId(bad), "非法 id \(bad)")
            XCTAssertNil(store.loadMacro(bad), "非法 id load 安全")
        }
        XCTAssertTrue(NativeCUMacroStore.validMacroId("cu-20260918-120000-test-a1b2"))
    }

    // ══════════════════════════════════════════════════════════
    // MARK: B 组 录制器（test_b_recorder）
    // ══════════════════════════════════════════════════════════

    func testB_recorder() {
        // B1 空名→bad_arg
        XCTAssertEqual(store.startRecording(name: "   ")["ok"]?.bool, false, "B1 空名→bad_arg")
        // B2 开始→ok 且 is_recording
        let r = store.startRecording(name: "我的流程")
        XCTAssertEqual(r["ok"]?.bool, true); XCTAssertTrue(store.isRecording(), "B2")
        XCTAssertEqual(r["mode"]?.string, "agent", "agent 模式（Python 默认零变化）")
        // B3 重复开始→already_recording（单例；conflict=False 端点语义同构）
        let r2 = store.startRecording(name: "另一个")
        XCTAssertEqual(r2["ok"]?.bool, false)
        XCTAssertTrue(r2["error"]?.string?.contains("already_recording") ?? false, "B3")
        XCTAssertEqual(r2["conflict"]?.bool, false)
        // B4 三步受理（element.title 200 字 → 落盘截 80；element nil 防御）
        XCTAssertTrue(store.recordStep(
            action: "click", x: 1, y: 2, app: "Finder",
            element: NativeCUMacroStore.StepElement(
                role: "AXButton", title: String(repeating: "长", count: 200),
                frame: [0, 0, 10, 10]),
            payload: ["button": .string("left"), "clicks": .int(1)]))
        XCTAssertTrue(store.recordStep(action: "type", x: nil, y: nil, app: "Finder",
                                       element: nil, payload: ["text": .string("你好")]))
        XCTAssertTrue(store.recordStep(action: "key", x: nil, y: nil, app: "",
                                       element: nil, payload: ["keys": .string("cmd+c")]))
        // B5 停止→ok 且 is_recording 复原
        let st = store.stopRecording()
        XCTAssertEqual(st["ok"]?.bool, true); XCTAssertFalse(store.isRecording(), "B5")
        let m = st["macro"]?.object
        XCTAssertTrue(m?["id"]?.string?.hasPrefix("cu-") ?? false, "B5b id 风格")
        XCTAssertEqual(m?["name"]?.string, "我的流程")
        XCTAssertFalse(m?["created_at"]?.string?.isEmpty ?? true, "B5b created_at")
        // B6 step 八字段齐全且 seq 自增
        let steps = m?["steps"]?.array?.compactMap { $0.object } ?? []
        XCTAssertEqual(steps.count, 3)
        XCTAssertEqual(steps.compactMap { $0["seq"]?.int }, [1, 2, 3], "B6 seq 自增")
        for s in steps {
            XCTAssertEqual(Set(s.keys), ["seq", "action", "x", "y", "app",
                                         "element", "payload", "ts"], "B6 字段齐全")
            XCTAssertFalse(s["ts"]?.string?.isEmpty ?? true)
        }
        // B7 title 截断 80（落盘契约）
        XCTAssertEqual(steps[0]["element"]?.object?["title"]?.string?.count, 80, "B7")
        // B7b element=None 防御 + payload 保留
        XCTAssertEqual(steps[2]["element"], .null, "B7b 非 dict element→None（类型防御）")
        XCTAssertEqual(steps[2]["payload"]?.object?["keys"]?.string, "cmd+c")
        // B8 落盘可读回
        XCTAssertEqual(store.loadMacro(m?["id"]?.string ?? "")?["steps"]?.array?.count, 3, "B8")
        // B9/B9b 未录制 stop/record_step
        XCTAssertEqual(store.stopRecording()["ok"]?.bool, false, "B9 not_recording")
        XCTAssertFalse(store.recordStep(action: "click", x: nil, y: nil, app: "",
                                        element: nil, payload: [:]), "B9b")
    }

    /// role 截断 40（ROLE_MAX 落盘契约；Python B7 同族防御）
    func testB_roleTruncated40() {
        _ = store.startRecording(name: "截断宏")
        _ = store.recordStep(action: "click", x: 1, y: 2, app: "A",
                             element: NativeCUMacroStore.StepElement(
                                role: String(repeating: "R", count: 100), title: "t",
                                frame: nil),
                             payload: [:])
        let st = store.stopRecording()
        let el = st["macro"]?.object?["steps"]?.array?[0].object?["element"]?.object
        XCTAssertEqual(el?["role"]?.string?.count, 40, "role ≤40 截断防御")
        XCTAssertEqual(el?["frame"], .null)
    }

    // ══════════════════════════════════════════════════════════
    // MARK: K 组 空宏防护 + recording_steps（test_k_empty_macro_guard）
    // ══════════════════════════════════════════════════════════

    func testK_emptyMacroGuard() {
        // K1-K3 recording_steps 生命周期
        XCTAssertEqual(store.recordingSteps(), 0, "K1 未录制=0")
        XCTAssertEqual(store.startRecording(name: "步数宏")["ok"]?.bool, true)
        XCTAssertEqual(store.recordingSteps(), 0, "K2 开始=0")
        _ = store.recordStep(action: "click", x: 1, y: 2, app: "Finder", element: nil,
                             payload: [:])
        _ = store.recordStep(action: "key", x: nil, y: nil, app: "Finder", element: nil,
                             payload: ["keys": .string("cmd+c")])
        XCTAssertEqual(store.recordingSteps(), 2, "K3 录制中递增")
        // K4/K5 有步 stop→saved=True + macro；步数归 0
        let st = store.stopRecording()
        XCTAssertEqual(st["ok"]?.bool, true); XCTAssertEqual(st["saved"]?.bool, true, "K4")
        XCTAssertEqual(st["macro"]?.object?["steps"]?.array?.count, 2)
        XCTAssertEqual(store.recordingSteps(), 0, "K5 停止归 0")
        // K6/K7 ⛔ 0 步 stop → 契约逐字且【不落盘】（变异 4 守护）
        let n0 = store.listMacros().count
        _ = store.startRecording(name: "空转宏")
        let st0 = store.stopRecording()
        XCTAssertEqual(st0["ok"]?.bool, true, "K6 0 步是契约不是失败")
        XCTAssertEqual(st0["saved"]?.bool, false)
        XCTAssertEqual(st0["steps"]?.int, 0)
        XCTAssertEqual(st0["message"]?.string, "未捕获到任何动作，宏未保存", "K6 契约逐字")
        XCTAssertEqual(store.listMacros().count, n0, "K7 0 步宏不落盘")
        // K8/K8b ⛔ 存量 0 步宏拒绝回放且忙锁未占用（变异 5 守护）
        try? store.saveMacro(macro("cu-20260918-125959-empty-e0f0", steps: []))
        let r = store.startReplay(macroId: "cu-20260918-125959-empty-e0f0")
        XCTAssertEqual(r["ok"]?.bool, false)
        XCTAssertTrue(r["error"]?.string?.contains("宏没有可回放的步骤") ?? false, "K8")
        let r2 = store.startReplay(macroId: "cu-20260918-125959-empty-e0f0")
        XCTAssertTrue(r2["error"]?.string?.contains("empty_macro") ?? false,
                      "K8b 忙锁未占用（可立即再判）")
    }

    /// K9/K9b：有步宏回放不受影响（done 且按原像素点击）
    func testK_nonEmptyReplayUnaffected() {
        try? store.saveMacro(macro("cu-20260918-125958-ok-o1k1",
                                   steps: [clickStep(1, x: 1, y: 2, element: .some(nil))]))
        let r = store.startReplay(macroId: "cu-20260918-125958-ok-o1k1")
        XCTAssertEqual(r["ok"]?.bool, true, "K9 start_replay")
        XCTAssertTrue(r["run_id"]?.string?.hasPrefix("run-") ?? false)
        let run = waitRun(r["run_id"]?.string ?? "")
        XCTAssertEqual(run?.status, "done", "K9b 回放 done")
        XCTAssertEqual(clicks.count, 1)
        XCTAssertEqual(clicks[0].x, 1); XCTAssertEqual(clicks[0].y, 2, "K9b 按原像素点击")
        XCTAssertEqual(clicks[0].button, "left"); XCTAssertEqual(clicks[0].clicks, 1)
    }

    /// start_replay 不存在宏 → not_found（路由层据此翻译 422 语义）
    func testReplay_notFound() {
        let r = store.startReplay(macroId: "cu-20990101-000000-none-zzzz")
        XCTAssertEqual(r["ok"]?.bool, false)
        XCTAssertEqual(r["error"]?.string, "not_found")
    }
}


// MARK: - C/D/E/F/G 组（录制挂钩与回放；test_cu_macro.py 同构）

extension NativeCUMacroTests {

    /// C 组引擎装配：假 CU 适配层 + 真引擎（执行面经引擎 init 回接到宏存储）。
    private func makeEngineHarness(
        frontmost: String = "FakeFront"
    ) -> (eng: NativeComputerUseEngine, ad: HookAdapter) {
        let ad = HookAdapter()
        ad.frontmost = frontmost
        let eng = NativeComputerUseEngine(
            adapter: ad, dataRoot: tmp!, configProvider: { [:] },
            authorizer: nil,
            macroStore: NativeCUMacroStore(dataRoot: tmp!, sleeper: { _ in }),
            sleeper: { _ in })
        return (eng, ad)
    }

    /// C1-C6：executor 录制挂钩（命中落语义 step / 失败不落 / 未录制零开销）
    func testC_executorHook() {
        let (eng, ad) = makeEngineHarness()
        let ms = eng.macroStore
        XCTAssertEqual(ms.startRecording(name: "挂钩宏")["ok"]?.bool, true)
        // C1：命中点击 → step 用校正链既有 hit_test（element+frame+app），坐标=frame 中心
        ad.hit = NativeCUElementHit(role: "AXButton", title: "存储",
                                    frame: (100, 200, 40, 20), app: "", pid: 0)
        let r = eng.mouseClick(x: .int(110), y: .int(210), button: "left", clicks: nil)
        XCTAssertEqual(r["ok"]?.bool, true)
        XCTAssertEqual(ms.recordingSteps(), 1)
        // C2：双击/右键映射
        _ = eng.mouseClick(x: .int(110), y: .int(210), button: "left", clicks: .int(2))
        _ = eng.mouseClick(x: .int(110), y: .int(210), button: "right", clicks: nil)
        // C3：未命中（pixel_fallback）→ element=None、原坐标、frontmost app
        ad.hit = nil
        _ = eng.mouseClick(x: .int(300), y: .int(400), button: "left", clicks: nil)
        // C4/C4b：type/key → payload 落盘，element=None
        _ = eng.keyboardType(text: "你好世界")
        _ = eng.keyboardHotkey(keys: "cmd+c")
        // C5：失败动作不落宏（bad_arg 未到执行层）
        let nBefore = ms.recordingSteps()
        let bad = eng.mouseClick(x: .string("x"), y: .int(1), button: "left", clicks: nil)
        XCTAssertEqual(bad["ok"]?.bool, false)
        XCTAssertEqual(ms.recordingSteps(), nBefore, "C5 失败动作不落 step")
        // C6：stop 落盘 6 步
        let st = ms.stopRecording()
        XCTAssertEqual(st["ok"]?.bool, true)
        let steps = st["macro"]?.object?["steps"]?.array?.compactMap { $0.object } ?? []
        XCTAssertEqual(steps.count, 6, "C6 stop 落盘 6 步")
        // C1 细节：action/坐标=frame 中心（120,210）
        XCTAssertEqual(steps[0]["action"]?.string, "click")
        XCTAssertEqual(steps[0]["x"]?.double, 120.0, "C1 坐标=frame 中心")
        XCTAssertEqual(steps[0]["y"]?.double, 210.0)
        // C1b：element 语义来自既有 hit_test（⛔ 不重复测——录制全程只调 3 次 hit_test：
        // 三次点击各一次校正链调用，录制挂钩零额外调用）
        let el = steps[0]["element"]?.object
        XCTAssertEqual(el?["role"]?.string, "AXButton")
        XCTAssertEqual(el?["title"]?.string, "存储")
        XCTAssertEqual(el?["frame"]?.array?.compactMap { $0.double }, [100, 200, 40, 20])
        // C1c：hit 带不出 app 时回落 frontmost
        XCTAssertEqual(steps[0]["app"]?.string, "FakeFront", "C1c app 回落 frontmost")
        // C2 细节：动作映射
        XCTAssertEqual(steps[1]["action"]?.string, "double_click", "C2 双击映射")
        XCTAssertEqual(steps[2]["action"]?.string, "right_click", "C2 右键映射")
        // C3 细节：pixel_fallback → element=None + 原坐标
        XCTAssertEqual(steps[3]["element"], .null, "C3 element=None")
        XCTAssertEqual(steps[3]["x"]?.double, 300); XCTAssertEqual(steps[3]["y"]?.double, 400)
        XCTAssertEqual(steps[3]["app"]?.string, "FakeFront")
        // C4 细节：type/key payload
        XCTAssertEqual(steps[4]["action"]?.string, "type")
        XCTAssertEqual(steps[4]["payload"]?.object?["text"]?.string, "你好世界")
        XCTAssertEqual(steps[4]["element"], .null)
        XCTAssertEqual(steps[4]["app"]?.string, "FakeFront")
        XCTAssertEqual(steps[5]["action"]?.string, "key")
        XCTAssertEqual(steps[5]["payload"]?.object?["keys"]?.string, "cmd+c")
        // C6b：未录制 → frontmost 零调用（录制挂钩零开销）
        ad.frontmostCalls = 0
        ad.hitCalls = 0
        ad.hit = NativeCUElementHit(role: "AXButton", title: "x",
                                    frame: (100, 200, 40, 20), app: "", pid: 0)
        _ = eng.mouseClick(x: .int(110), y: .int(210), button: "left", clicks: nil)
        XCTAssertEqual(ad.frontmostCalls, 0, "C6b 未录制→frontmost 零调用")
        XCTAssertEqual(ad.hitCalls, 1, "录制挂钩不重复 hit_test（仅校正链那一次）")
    }

    // ══════════════════════════════════════════════════════════
    // MARK: D 组 回放语义重定位（test_d_replay_relocate）
    // ══════════════════════════════════════════════════════════

    /// D1/D1b：窗口挪位仍命中 → 点新 frame 中心（⛔ title 必须参与匹配，变异 1 守护）
    func testD_replayRelocate() {
        stubElements = [
            NativeCUElementHit(role: "AXButton", title: "保存",
                               frame: (0, 0, 10, 10), app: "FakeApp", pid: 1),
            NativeCUElementHit(role: "AXButton", title: "删除",
                               frame: (500, 600, 40, 20), app: "FakeApp", pid: 1),
        ]
        let m = macro("cu-20260918-120000-test-a1b2", steps: [clickStep(1, x: 110, y: 210)])
        let r = store.startReplay(macroId: m["id"]!.string!)
        XCTAssertEqual(r["ok"]?.bool, false, "未落盘宏 not_found")
        try? store.saveMacro(m)
        let r2 = store.startReplay(macroId: m["id"]!.string!)
        let run = waitRun(r2["run_id"]?.string ?? "")
        XCTAssertEqual(run?.status, "done"); XCTAssertEqual(run?.completed, 1)
        XCTAssertEqual(clicks.count, 1)
        XCTAssertEqual(clicks[0].x, 520.0); XCTAssertEqual(clicks[0].y, 610.0,
                       "D1 ⛔点挪位后 frame 中心（title 匹配，不错点「保存」）")
        XCTAssertEqual(run?.steps[0]["method"]?.string, "element", "D1b method=element")
        XCTAssertEqual(run?.steps[0]["ok"]?.bool, true)
        XCTAssertEqual(enumCalls.first?.depth, 2, "D2b 枚举深度 ≤2（禁全树遍历）")
    }

    /// D2：double_click/right_click 映射（button/clicks 正确传给执行面）
    func testD_replayActionMapping() {
        stubElements = [NativeCUElementHit(role: "AXButton", title: "删除",
                                           frame: (500, 600, 40, 20), app: "FakeApp", pid: 1)]
        let m = macro("cu-20260918-120000-test-a1b2",
                      steps: [clickStep(1, action: "double_click"),
                              clickStep(2, action: "right_click")])
        try? store.saveMacro(m)
        let r = store.startReplay(macroId: m["id"]!.string!)
        let run = waitRun(r["run_id"]?.string ?? "")
        XCTAssertEqual(run?.status, "done")
        XCTAssertEqual(clicks.count, 2)
        XCTAssertEqual(clicks[0].button, "left"); XCTAssertEqual(clicks[0].clicks, 2,
                       "D2 double→left×2")
        XCTAssertEqual(clicks[1].button, "right"); XCTAssertEqual(clicks[1].clicks, 1,
                       "D2 right→right×1")
    }

    // ══════════════════════════════════════════════════════════
    // MARK: E 组 回放回落像素（test_e_replay_fallback）
    // ══════════════════════════════════════════════════════════

    /// E1：枚举有元素但 role/title 不匹配 → 回落 step 原像素（变异 2 守护）
    func testE_noMatchFallsBackToPixel() {
        stubElements = [NativeCUElementHit(role: "AXSlider", title: "别的",
                                           frame: (0, 0, 5, 5), app: "FakeApp", pid: 1)]
        let m = macro("cu-20260918-120000-test-a1b2", steps: [clickStep(1, x: 110, y: 210)])
        try? store.saveMacro(m)
        let r = store.startReplay(macroId: m["id"]!.string!)
        let run = waitRun(r["run_id"]?.string ?? "")
        XCTAssertEqual(run?.status, "done")
        XCTAssertEqual(clicks[0].x, 110); XCTAssertEqual(clicks[0].y, 210, "E1 回落原像素")
        XCTAssertEqual(run?.steps[0]["method"]?.string, "pixel_fallback")
    }

    /// E2：录制时本无元素语义 → 直接像素回落且零枚举开销
    func testE_noElementSkipsEnumeration() {
        let m = macro("cu-20260918-120000-test-a1b2",
                      steps: [clickStep(1, x: 33, y: 44, element: .some(nil))])
        try? store.saveMacro(m)
        let r = store.startReplay(macroId: m["id"]!.string!)
        let run = waitRun(r["run_id"]?.string ?? "")
        XCTAssertEqual(run?.status, "done")
        XCTAssertEqual(clicks[0].x, 33); XCTAssertEqual(clicks[0].y, 44)
        XCTAssertTrue(enumCalls.isEmpty, "E2 零枚举开销")
    }

    /// E3：枚举失败（非 app 缺失）→ 回落像素不中止
    func testE_enumFailureNonFatal() {
        stubElements = []
        stubLastError = "AXWindows err=-25204(cannotComplete)"
        let m = macro("cu-20260918-120000-test-a1b2", steps: [clickStep(1, x: 55, y: 66)])
        try? store.saveMacro(m)
        let r = store.startReplay(macroId: m["id"]!.string!)
        let run = waitRun(r["run_id"]?.string ?? "")
        XCTAssertEqual(run?.status, "done", "E3 枚举失败不中止")
        XCTAssertEqual(clicks[0].x, 55); XCTAssertEqual(clicks[0].y, 66, "E3 回落像素")
    }

    // ══════════════════════════════════════════════════════════
    // MARK: F 组 R4 中止（test_f_replay_abort；⛔ 变异 3 守护）
    // ══════════════════════════════════════════════════════════

    /// F1/F1b/F1c：app 未运行 → 第 2 步中止报步骤号，后续步骤绝不执行
    func testF_appMissingAborts() {
        stubElements = []
        stubLastError = "app_not_found: 找不到运行中的应用「FakeApp」"
        let m = macro("cu-20260918-120000-test-a1b2", steps: [
            ["seq": .int(1), "action": .string("type"), "x": .null, "y": .null,
             "app": .string("FakeApp"), "element": .null,
             "payload": .object(["text": .string("先输入")]), "ts": .string("t")],
            clickStep(2, x: 10, y: 10),
            clickStep(3, x: 20, y: 20),
        ])
        try? store.saveMacro(m)
        let r = store.startReplay(macroId: m["id"]!.string!)
        let run = waitRun(r["run_id"]?.string ?? "")
        XCTAssertEqual(run?.status, "error", "F1 app 未运行→中止")
        XCTAssertEqual(run?.failedSeq, 2, "F1 报步骤号")
        XCTAssertTrue(run?.error.contains("第 2 步") ?? false)
        XCTAssertTrue(run?.error.contains("FakeApp") ?? false)
        XCTAssertEqual(types, ["先输入"], "F1b 后续步骤未执行")
        XCTAssertTrue(clicks.isEmpty, "F1b 第 3 步没有点出去")
        XCTAssertEqual(run?.steps.count, 2, "F1c 步骤明细只到失败步")
        XCTAssertEqual(run?.steps[0]["ok"]?.bool, true)
        XCTAssertEqual(run?.steps[1]["ok"]?.bool, false)
        XCTAssertEqual(run?.steps[1]["method"]?.string, "abort")
    }

    /// F2：动作执行失败 → 同样中止报步骤号（后续不执行）
    func testF_execFailureAborts() {
        execOK = false
        stubElements = [NativeCUElementHit(role: "AXButton", title: "删除",
                                           frame: (1, 1, 4, 4), app: "FakeApp", pid: 1)]
        let m = macro("cu-20260918-120000-test-a1b2", steps: [clickStep(1), clickStep(2)])
        try? store.saveMacro(m)
        let r = store.startReplay(macroId: m["id"]!.string!)
        let run = waitRun(r["run_id"]?.string ?? "")
        XCTAssertEqual(run?.status, "error"); XCTAssertEqual(run?.failedSeq, 1)
        XCTAssertEqual(clicks.count, 1, "F2 失败即中止（后续不执行）")
    }

    /// F3：未知动作（宏文件损坏）→ 中止，不猜不跳过
    func testF_unknownActionAborts() {
        let m = macro("cu-20260918-120000-test-a1b2", steps: [
            ["seq": .int(1), "action": .string("teleport"), "x": .double(1), "y": .double(2),
             "app": .string(""), "element": .null, "payload": .object([:]), "ts": .string("t")],
        ])
        try? store.saveMacro(m)
        let r = store.startReplay(macroId: m["id"]!.string!)
        let run = waitRun(r["run_id"]?.string ?? "")
        XCTAssertEqual(run?.status, "error"); XCTAssertEqual(run?.failedSeq, 1)
        XCTAssertTrue(run?.error.contains("unknown_action") ?? false, "F3 unknown_action")
    }

    // ══════════════════════════════════════════════════════════
    // MARK: G 组 type/key 直接重放 payload（test_g_replay_payload）
    // ══════════════════════════════════════════════════════════

    func testG_payloadReplay() {
        let m = macro("cu-20260918-120000-test-a1b2", steps: [
            ["seq": .int(1), "action": .string("type"), "x": .null, "y": .null,
             "app": .string("备忘录"), "element": .null,
             "payload": .object(["text": .string("会议纪要")]), "ts": .string("t")],
            ["seq": .int(2), "action": .string("key"), "x": .null, "y": .null,
             "app": .string("备忘录"), "element": .null,
             "payload": .object(["keys": .string("cmd+s")]), "ts": .string("t")],
        ])
        try? store.saveMacro(m)
        let r = store.startReplay(macroId: m["id"]!.string!)
        let run = waitRun(r["run_id"]?.string ?? "")
        XCTAssertEqual(run?.status, "done")
        XCTAssertEqual(types, ["会议纪要"], "G1 type 按 payload 重放")
        XCTAssertEqual(keys, ["cmd+s"], "G1 key 按 payload 重放")
        XCTAssertEqual(run?.steps.compactMap { $0["method"]?.string },
                       ["payload", "payload"], "G1 method=payload")
    }

    /// 真实键鼠独占：回放进行中第二个 start_replay → replay_busy（信号量闸门确定性）
    func testReplay_busyGuard() {
        let entered = DispatchSemaphore(value: 0)
        let gate = DispatchSemaphore(value: 0)
        store.typeExecutor = { _ in
            entered.signal()
            _ = gate.wait(timeout: .now() + 5)
            return ["ok": .bool(true)]
        }
        let m = macro("cu-20260918-120000-busy-b1b2", steps: [
            ["seq": .int(1), "action": .string("type"), "x": .null, "y": .null,
             "app": .string("A"), "element": .null,
             "payload": .object(["text": .string("闸门")]), "ts": .string("t")],
            clickStep(2),
        ])
        try? store.saveMacro(m)
        let r1 = store.startReplay(macroId: m["id"]!.string!)
        XCTAssertEqual(r1["ok"]?.bool, true)
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success, "回放已进入第一步")
        let r2 = store.startReplay(macroId: m["id"]!.string!)
        XCTAssertEqual(r2["ok"]?.bool, false, "真实键鼠是独占资源")
        XCTAssertTrue(r2["error"]?.string?.contains("replay_busy") ?? false,
                      "忙时 replay_busy（并发回放会互相踩坐标）")
        gate.signal()
        let run = waitRun(r1["run_id"]?.string ?? "")
        XCTAssertEqual(run?.status, "done")
        // 忙锁释放后可再次回放（K8b 守护方向）
        store.typeExecutor = { _ in ["ok": .bool(true)] }   // 解除闸门
        let r3 = store.startReplay(macroId: m["id"]!.string!)
        XCTAssertEqual(r3["ok"]?.bool, true, "完成后忙锁释放可再回放")
        _ = waitRun(r3["run_id"]?.string ?? "")
    }
}

// MARK: - 挂钩用假适配层（test_cu_macro.py C 组 FakeAS/FakeCG 同构）

private final class HookAdapter: NativeCUPlatformAdapter, @unchecked Sendable {
    var ax: Bool? = true
    var frontmost = "FakeFront"
    var hit: NativeCUElementHit?
    var frontmostCalls = 0
    var hitCalls = 0
    var buttons: [(down: Bool, button: String, x: Double, y: Double, clickState: Int)] = []
    var keys: [(keyCode: UInt16, down: Bool, flags: UInt64, units: [UInt16])] = []
    func axTrusted() -> Bool? { ax }
    func screenCaptureAccess() -> Bool? { true }
    func screenGeometry() -> (Int, Int) { (1728, 1117) }
    func captureScreenshot(maxLongEdge: Int, jpegQuality: Int) throws -> NativeCUScreenshot {
        NativeCUScreenshot(jpegData: Data(), widthPx: 2, heightPx: 2,
                           sentWidth: 2, sentHeight: 2)
    }
    func postMouseMove(x: Double, y: Double) throws {}
    func postMouseButton(down: Bool, button: String, x: Double, y: Double,
                         clickState: Int) throws {
        buttons.append((down, button, x, y, clickState))
    }
    func postKeyboard(keyCode: UInt16, down: Bool, flags: UInt64,
                      unicodeUnits: [UInt16]) throws {
        keys.append((keyCode, down, flags, unicodeUnits))
    }
    func hitTest(x: Double, y: Double) -> NativeCUElementHit? { hitCalls += 1; return hit }
    func appElements(app: String, depth: Int) -> [NativeCUElementHit] { [] }
    func axLastError() -> String { "" }
    func frontmostApp() -> String { frontmostCalls += 1; return frontmost }
}


// MARK: - AG-B/C/D 组 工具层契约（test_cu_macro_agent.py；引擎路由层）

final class NativeCUMacroRouteTests: XCTestCase {

    private var tmp: URL!
    private var adapter: HookAdapter!
    private var config: [String: JSONValue] = [:]
    private var authzCalls: [(tool: String, path: String, action: String)] = []
    private var authzAnswer = true
    private var withAuthz = true
    private var eng: NativeComputerUseEngine!

    override func setUp() {
        super.setUp()
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("p2w4c_mroute_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        adapter = HookAdapter()
        config = ["computer_use_confirm_each": .bool(false),
                  "computer_use_app_whitelist": .array([])]
        authzCalls = []; authzAnswer = true; withAuthz = true
        eng = nil
    }

    override func tearDown() {
        if let tmp { try? FileManager.default.removeItem(at: tmp) }
        super.tearDown()
    }

    /// 引擎惰性装配（withAuthorizer/config 先配后造）。
    private func engine() -> NativeComputerUseEngine {
        if let eng { return eng }
        let authz: NativeCallbackAuthorizer? = withAuthz
            ? NativeCallbackAuthorizer(onAuthorize: { [self] t, p, a in
                self.authzCalls.append((t, p, a)); return self.authzAnswer
            })
            : nil
        eng = NativeComputerUseEngine(
            adapter: adapter, dataRoot: tmp,
            configProvider: { [self] in self.config },
            authorizer: authz, sleeper: { _ in })
        return eng
    }

    private func clickStep(_ seq: Int, x: Double = 10, y: Double = 10)
        -> [String: JSONValue] {
        ["seq": .int(Int64(seq)), "action": .string("click"),
         "x": .double(x), "y": .double(y), "app": .string("FakeApp"),
         "element": .object(["role": .string("AXButton"), "title": .string("删除"),
                             "frame": .array([100.0, 200.0, 40.0, 20.0].map { .double($0) })]),
         "payload": .object([:]), "ts": .string("t")]
    }

    private func saveMacro(_ id: String, name: String, steps: [[String: JSONValue]],
                           created: String = "2026-09-20T12:00:00") {
        try? engine().macroStore.saveMacro(
            ["id": .string(id), "name": .string(name), "created_at": .string(created),
             "steps": .array(steps.map { .object($0) })])
    }

    private func waitRun(_ runId: String) -> NativeCUMacroStore.ReplayRun? {
        let deadline = Date().addingTimeInterval(3)
        var run = engine().macroStore.getRun(runId)
        while run?.status == "running", Date() < deadline {
            Thread.sleep(forTimeInterval: 0.005)
            run = engine().macroStore.getRun(runId)
        }
        return run
    }

    // ══════════════════════════════════════════════════════════
    // MARK: AG-B 组 record start/stop 经工具层（test_b_record_contract）
    // ══════════════════════════════════════════════════════════

    func testAGB_recordContract() async {
        let e = engine()
        // B1/B1b：start 带 name → ok，透传契约（ok+name），单例生效
        let r1 = await e.executeComputerUse("cu_macro_record",
                                            args: ["action": .string("start"),
                                                   "name": .string("宏甲")])
        XCTAssertEqual(r1["ok"]?.bool, true, "B1 start 经工具层→ok")
        XCTAssertEqual(r1["name"]?.string, "宏甲", "B1b 透传契约")
        XCTAssertTrue(e.macroStore.isRecording())
        // B2：重复 start → already_recording 可读错误（不熔断不弹窗）
        let r2 = await e.executeComputerUse("cu_macro_record",
                                            args: ["action": .string("start"),
                                                   "name": .string("宏乙")])
        XCTAssertEqual(r2["ok"]?.bool, false)
        XCTAssertTrue(r2["error"]?.string?.contains("already_recording") ?? false, "B2")
        XCTAssertTrue(r2["error"]?.string?.contains("宏甲") ?? false)
        // B3：落 2 步 → stop saved=True + 宏 id + 步数=2
        _ = e.macroStore.recordStep(action: "click", x: 1, y: 2, app: "FakeApp",
                                    element: nil, payload: [:])
        _ = e.macroStore.recordStep(action: "type", x: nil, y: nil, app: "FakeApp",
                                    element: nil, payload: ["text": .string("你好")])
        let r3 = await e.executeComputerUse("cu_macro_record",
                                            args: ["action": .string("stop")])
        XCTAssertEqual(r3["ok"]?.bool, true)
        XCTAssertEqual(r3["saved"]?.bool, true, "B3 有步 stop→saved=True")
        XCTAssertTrue(r3["macro"]?.object?["id"]?.string?.hasPrefix("cu-") ?? false)
        XCTAssertEqual(r3["macro"]?.object?["steps"]?.array?.count, 2, "B3 步数=2")
        // B4/B4b：⛔ 0 步 stop → 契约逐字且宏未落盘（变异 4 守护经工具层）
        _ = await e.executeComputerUse("cu_macro_record",
                                       args: ["action": .string("start"),
                                              "name": .string("空转宏")])
        let n0 = e.macroStore.listMacros().count
        let r4 = await e.executeComputerUse("cu_macro_record",
                                            args: ["action": .string("stop")])
        XCTAssertEqual(r4["ok"]?.bool, true, "B4b 0 步是契约不是失败")
        XCTAssertEqual(r4["saved"]?.bool, false)
        XCTAssertEqual(r4["steps"]?.int, 0)
        XCTAssertEqual(r4["message"]?.string, "未捕获到任何动作，宏未保存", "B4 契约逐字")
        XCTAssertEqual(e.macroStore.listMacros().count, n0, "B4b 0 步未落盘")
        // B5：未录制 stop → not_recording
        let r5 = await e.executeComputerUse("cu_macro_record",
                                            args: ["action": .string("stop")])
        XCTAssertEqual(r5["ok"]?.bool, false)
        XCTAssertTrue(r5["error"]?.string?.contains("not_recording") ?? false, "B5")
        // B6：非法 action → bad_arg（不触模块）
        let r6 = await e.executeComputerUse("cu_macro_record",
                                            args: ["action": .string("pause")])
        XCTAssertEqual(r6["ok"]?.bool, false)
        XCTAssertTrue(r6["error"]?.string?.contains("bad_arg") ?? false, "B6")
        XCTAssertTrue(r6["error"]?.string?.contains("start/stop") ?? false)
        XCTAssertFalse(e.macroStore.isRecording(), "B6 未触模块")
        // B7：空名 start → bad_arg 宏名称不能为空
        let r7 = await e.executeComputerUse("cu_macro_record",
                                            args: ["action": .string("start"),
                                                   "name": .string("   ")])
        XCTAssertEqual(r7["ok"]?.bool, false)
        XCTAssertTrue(r7["error"]?.string?.contains("bad_arg") ?? false)
        XCTAssertTrue(r7["error"]?.string?.contains("宏名称") ?? false, "B7")
        // B8：⛔ record 全程零确认弹窗（纯状态操作，同 screen_view 只读纪律）
        XCTAssertTrue(authzCalls.isEmpty, "B8 record 全程不弹确认")
    }

    // ══════════════════════════════════════════════════════════
    // MARK: AG-C 组 replay 经工具层（test_c_replay_routing）
    // ══════════════════════════════════════════════════════════

    /// C1/C2/C4/C6：not_found / empty_macro / 无匹配名 / 缺参 的可读翻译
    func testAGC_replayErrorTranslation() async {
        saveMacro("cu-20260920-120001-empty-c3d4", name: "空宏", steps: [])
        let e = engine()
        // C1：不存在 id → not_found 可读翻译
        let r1 = await e.executeComputerUse("cu_macro_replay",
                                            args: ["id": .string("cu-20990101-000000-none-zzzz")])
        XCTAssertEqual(r1["ok"]?.bool, false)
        XCTAssertTrue(r1["error"]?.string?.contains("不存在或已删除") ?? false, "C1 not_found 翻译")
        XCTAssertTrue(r1["error"]?.string?.contains("cu_macro_list") ?? false)
        // C2：⛔ 0 步宏 → empty_macro 可读文本（静默完成等于假成功）
        let r2 = await e.executeComputerUse("cu_macro_replay",
                                            args: ["id": .string("cu-20260920-120001-empty-c3d4")])
        XCTAssertEqual(r2["ok"]?.bool, false)
        XCTAssertTrue(r2["error"]?.string?.contains("宏没有可回放的步骤") ?? false, "C2")
        // C4：name 无匹配 → not_found 含名字与 list 指引
        let r4 = await e.executeComputerUse("cu_macro_replay",
                                            args: ["name": .string("不存在名")])
        XCTAssertEqual(r4["ok"]?.bool, false)
        XCTAssertTrue(r4["error"]?.string?.contains("not_found") ?? false, "C4")
        XCTAssertTrue(r4["error"]?.string?.contains("不存在名") ?? false)
        XCTAssertTrue(r4["error"]?.string?.contains("cu_macro_list") ?? false)
        // C6：缺 id/name → bad_arg 指引先 list
        let r6 = await e.executeComputerUse("cu_macro_replay", args: [:])
        XCTAssertEqual(r6["ok"]?.bool, false)
        XCTAssertTrue(r6["error"]?.string?.contains("bad_arg") ?? false, "C6")
        XCTAssertTrue(r6["error"]?.string?.contains("cu_macro_list") ?? false)
    }

    /// C3/C3b/C3d：name 唯一匹配 → 回放启动（confirm_each 关零弹窗）+ 异步提示
    func testAGC_replayByUniqueName() async {
        saveMacro("cu-20260920-120000-one-a1b2", name: "唯一宏",
                  steps: [clickStep(1, x: 1, y: 2)])
        let e = engine()
        let r = await e.executeComputerUse("cu_macro_replay",
                                           args: ["name": .string("唯一宏")])
        XCTAssertEqual(r["ok"]?.bool, true, "C3 唯一匹配→回放启动")
        XCTAssertTrue(r["run_id"]?.string?.hasPrefix("run-") ?? false, "C3 run_id 透传")
        XCTAssertTrue(r["hint"]?.string?.contains("后台") ?? false, "C3b 异步提示别干等")
        XCTAssertTrue(r["hint"]?.string?.contains("screen_view") ?? false, "C3b 可截屏核对")
        let run = waitRun(r["run_id"]?.string ?? "")
        XCTAssertEqual(run?.status, "done", "C3c 回放完成")
        // 像素回落（provider 空 + lastError 无 app 缺失键）点击录制坐标 (1,2)
        XCTAssertEqual(adapter.buttons.count, 2, "C3c down/up 各一")
        XCTAssertEqual(adapter.buttons[0].x, 1); XCTAssertEqual(adapter.buttons[0].y, 2)
        XCTAssertTrue(authzCalls.isEmpty, "C3d confirm_each 关→零弹窗")
    }

    /// C5/C5b：⛔ 同名多个 → ambiguous 列候选 id 且【绝不】启动回放（变异 1 守护）
    func testAGC_replayAmbiguousNeverStarts() async {
        saveMacro("cu-20260920-120003-dup1-g7h8", name: "同名宏", steps: [clickStep(1)])
        saveMacro("cu-20260920-120004-dup2-i9j0", name: "同名宏", steps: [clickStep(1)],
                  created: "2026-09-20T12:01:00")
        let e = engine()
        let r = await e.executeComputerUse("cu_macro_replay",
                                           args: ["name": .string("同名宏")])
        let err = r["error"]?.string ?? ""
        XCTAssertEqual(r["ok"]?.bool, false)
        XCTAssertTrue(err.contains("ambiguous"), "C5 ambiguous")
        XCTAssertTrue(err.contains("cu-20260920-120003-dup1-g7h8"), "C5 列候选 id")
        XCTAssertTrue(err.contains("cu-20260920-120004-dup2-i9j0"))
        XCTAssertTrue(err.contains("id"), "C5 要求改用 id 指定")
        XCTAssertTrue(adapter.buttons.isEmpty, "C5b ambiguous 绝不启动回放")
    }

    /// C7/C7b/C7c/C7d：整宏【一次】确认（2 步宏也只弹一次；逐步=弹窗风暴同款事故）
    func testAGC_replayWholeMacroSingleConfirm() async {
        saveMacro("cu-20260920-120002-two-e5f6", name: "两步宏", steps: [
            clickStep(1, x: 5, y: 6),
            ["seq": .int(2), "action": .string("type"), "x": .null, "y": .null,
             "app": .string("FakeApp"), "element": .null,
             "payload": .object(["text": .string("宏输入")]), "ts": .string("t")],
        ])
        config["computer_use_confirm_each"] = .bool(true)
        let e = engine()
        let r = await e.executeComputerUse(
            "cu_macro_replay", args: ["id": .string("cu-20260920-120002-two-e5f6")])
        XCTAssertEqual(r["ok"]?.bool, true, "C7 同意→回放启动")
        XCTAssertEqual(authzCalls.count, 1, "C7b ⛔ 2 步宏只弹一次确认（整宏一次）")
        // C7c 确认请求契约（原生协议三参：tool/path/action；args 随 path JSON）
        XCTAssertEqual(authzCalls[0].tool, "computer_use:cu_macro_replay")
        XCTAssertEqual(authzCalls[0].action, "computer_use")
        XCTAssertTrue(authzCalls[0].path.contains("cu-20260920-120002-two-e5f6"),
                      "C7c 确认请求带宏 id")
        let run = waitRun(r["run_id"]?.string ?? "")
        XCTAssertEqual(run?.status, "done", "C7d 2 步宏回放完成")
        XCTAssertEqual(adapter.buttons.count, 2, "C7d click 重放")
        XCTAssertEqual(adapter.buttons[0].x, 5); XCTAssertEqual(adapter.buttons[0].y, 6)
        let typedUnits = adapter.keys.first(where: { $0.down })?.units ?? []
        XCTAssertEqual(String(utf16CodeUnits: typedUnits, count: typedUnits.count), "宏输入",
                       "C7d type 重放")
    }

    /// C8/C8b：用户拒绝 → denied_by_user + 禁止重试，【绝不】启动回放
    func testAGC_replayDeniedByUser() async {
        saveMacro("cu-20260920-120000-one-a1b2", name: "唯一宏", steps: [clickStep(1)])
        config["computer_use_confirm_each"] = .bool(true)
        authzAnswer = false
        let e = engine()
        let r = await e.executeComputerUse(
            "cu_macro_replay", args: ["id": .string("cu-20260920-120000-one-a1b2")])
        let err = r["error"]?.string ?? ""
        XCTAssertEqual(r["ok"]?.bool, false)
        XCTAssertTrue(err.contains("denied_by_user"), "C8 denied_by_user")
        XCTAssertTrue(err.contains("不要再重试"), "C8 禁止重试")
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertTrue(adapter.buttons.isEmpty, "C8b 拒绝时回放绝未启动")
    }

    /// C9：需确认但无授权通道 → computer_use_denied（不擅自操作电脑）
    func testAGC_replayNoAuthChannel() async {
        withAuthz = false     // 必须先于 engine() 惰性装配（saveMacro 会触发创建）
        config["computer_use_confirm_each"] = .bool(true)
        saveMacro("cu-20260920-120000-one-a1b2", name: "唯一宏", steps: [clickStep(1)])
        let e = engine()
        let r = await e.executeComputerUse(
            "cu_macro_replay", args: ["id": .string("cu-20260920-120000-one-a1b2")])
        XCTAssertEqual(r["ok"]?.bool, false)
        XCTAssertTrue(r["error"]?.string?.contains("computer_use_denied") ?? false, "C9")
        XCTAssertTrue(adapter.buttons.isEmpty)
    }

    /// C10：防线4 白名单不命中 → app_not_allowed，不弹窗不启动
    func testAGC_replayWhitelistMiss() async {
        saveMacro("cu-20260920-120000-one-a1b2", name: "唯一宏", steps: [clickStep(1)])
        adapter.frontmost = "Safari"
        config["computer_use_app_whitelist"] = .array([.string("Finder")])
        config["computer_use_confirm_each"] = .bool(true)
        let e = engine()
        let r = await e.executeComputerUse(
            "cu_macro_replay", args: ["id": .string("cu-20260920-120000-one-a1b2")])
        XCTAssertEqual(r["ok"]?.bool, false)
        XCTAssertTrue(r["error"]?.string?.contains("app_not_allowed") ?? false, "C10")
        XCTAssertTrue(authzCalls.isEmpty, "C10 白名单拦截在弹窗前")
        XCTAssertTrue(adapter.buttons.isEmpty, "C10 未启动")
    }

    /// C11/C11b：防线1 权限缺失 → 弹窗前拦截（以 cu_macro_replay 名义走辅助功能路径）
    func testAGC_replayPermissionPreflight() async {
        saveMacro("cu-20260920-120000-one-a1b2", name: "唯一宏", steps: [clickStep(1)])
        adapter.ax = false
        config["computer_use_confirm_each"] = .bool(true)
        let e = engine()
        let r = await e.executeComputerUse(
            "cu_macro_replay", args: ["id": .string("cu-20260920-120000-one-a1b2")])
        XCTAssertEqual(r["ok"]?.bool, false)
        XCTAssertTrue(r["error"]?.string?.contains("accessibility_denied") ?? false, "C11")
        XCTAssertTrue(authzCalls.isEmpty, "C11 弹窗前拦截")
        XCTAssertTrue(adapter.buttons.isEmpty, "C11 未启动")
    }

    // ══════════════════════════════════════════════════════════
    // MARK: AG-D 组 list 经工具层（test_d_list_contract）
    // ══════════════════════════════════════════════════════════

    func testAGD_listContract() async {
        saveMacro("cu-20260920-130000-aa-a1a1", name: "甲",
                  steps: [clickStep(1), clickStep(2)])
        saveMacro("cu-20260920-130001-bb-b2b2", name: "乙", steps: [],
                  created: "2026-09-20T13:00:01")
        let e = engine()
        let r = await e.executeComputerUse("cu_macro_list", args: [:])
        // D1/D1b：ok + 摘要字段逐字（id/name/created_at/steps 数）
        XCTAssertEqual(r["ok"]?.bool, true, "D1 list 经工具层→ok")
        let macros = r["macros"]?.array?.compactMap { $0.object } ?? []
        XCTAssertEqual(macros.count, 2)
        XCTAssertEqual(macros[0]["id"]?.string, "cu-20260920-130000-aa-a1a1")
        XCTAssertEqual(macros[0]["name"]?.string, "甲")
        XCTAssertEqual(macros[0]["created_at"]?.string, "2026-09-20T12:00:00")
        XCTAssertEqual(macros[0]["steps"]?.int, 2, "D1b steps 为数")
        XCTAssertEqual(macros[1]["steps"]?.int, 0)
        // D1c：录制状态字段一并带出
        XCTAssertEqual(r["recording"]?.bool, false, "D1c recording 字段")
        XCTAssertEqual(r["recording_steps"]?.int, 0)
        // D2：录制中 list → recording=True / steps=1
        _ = e.macroStore.startRecording(name: "进行中")
        _ = e.macroStore.recordStep(action: "click", x: 1, y: 1, app: "A", element: nil,
                                    payload: [:])
        let r2 = await e.executeComputerUse("cu_macro_list", args: [:])
        XCTAssertEqual(r2["recording"]?.bool, true, "D2 录制中 recording=True")
        XCTAssertEqual(r2["recording_steps"]?.int, 1, "D2 实时步数")
        // D3：list 全程不弹确认（只读，同 screen_view 纪律）
        XCTAssertTrue(authzCalls.isEmpty, "D3 list 不弹确认")
    }
}


// ══════════════════════════════════════════════════════════
// MARK: 0.7.4 W5 命中率全程审计聚合（macroAuditSummary）
// ══════════════════════════════════════════════════════════

extension NativeCUMacroTests {

    /// 聚合口径：宏两步（第一步 element 命中、第二步像素回落）跑两次回放——
    /// 一次全成（done）、一次第一步执行失败中止（error）→
    /// replays=2 / successes=1 / elementHits=2 / pixelFallbacks=1。
    func testMacroAuditSummaryAggregation() {
        // step1 有元素语义且枚举能匹配 → method=element；step2 无元素语义 → pixel_fallback
        stubElements = [NativeCUElementHit(role: "AXButton", title: "删除",
                                           frame: (500, 600, 40, 20), app: "FakeApp", pid: 1)]
        let m = macro("cu-20260918-120000-test-a1b2",
                      steps: [clickStep(1, x: 110, y: 210),
                              clickStep(2, x: 33, y: 44, element: .some(nil))])
        try? store.saveMacro(m)

        // 第 1 次：全成（done）→ steps [element, pixel_fallback]
        let r1 = store.startReplay(macroId: m["id"]!.string!)
        let run1 = waitRun(r1["run_id"]?.string ?? "")
        XCTAssertEqual(run1?.status, "done")
        XCTAssertEqual(run1?.steps.count, 2)

        // 第 2 次：第一步执行失败 → 中止（error）→ steps [element(ok:false)]
        execOK = false
        let r2 = store.startReplay(macroId: m["id"]!.string!)
        let run2 = waitRun(r2["run_id"]?.string ?? "")
        XCTAssertEqual(run2?.status, "error")

        let entries = store.macroAuditSummary()
        XCTAssertEqual(entries.count, 1, "按 macroId 聚合为一行")
        let e = entries[0]
        XCTAssertEqual(e.macroId, "cu-20260918-120000-test-a1b2")
        XCTAssertEqual(e.macroName, "测试宏")
        XCTAssertEqual(e.replays, 2, "回放 2 次")
        XCTAssertEqual(e.successes, 1, "成功 1 次（status==done 口径）")
        XCTAssertEqual(e.elementHits, 2, "两次回放的第一步都是 element 命中")
        XCTAssertEqual(e.pixelFallbacks, 1, "仅第一次回放走到第二步（像素回落）")
    }

    /// 空库：无回放记录 → 空聚合（进程内口径，重启即空）。
    func testMacroAuditSummaryEmpty() {
        XCTAssertTrue(store.macroAuditSummary().isEmpty)
    }
}
