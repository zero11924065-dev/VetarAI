//
//  NativeComputerUseTests.swift
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

//  逐条翻译 subagent/sidecar/computer_use/test_computer_use.py（⛔ 只读行为规格源）
//  与 test_ax_element.py 的 C/D/E 组（校正链/点击/element_locate——这三组在 Python
//  侧经 FakeAS/FakeCG 假层驱动，原生侧经 FakeCUAdapter 协议注入，同构）：
//    · B 组 执行层校验拒绝（bad_arg/NaN/inf/越界/button/too_long/unknown_key/4键/双主键）
//    · C 组 截屏契约与 coord_factor 换算（假捕获层给固定几何，⛔ 不真截屏）
//    · D 组 路由层防线 4→1→3 顺序（白名单/权限/每步确认；⛔ 不真动鼠标键盘）
//    · E 组 白名单纯逻辑（逐字拒绝文案）
//    · G 组 纯逻辑（UTF-16 代理对/safe_num/keycode 表/几何缓存）
//    · H 组 权限前置拦截（弹窗之前）+ 连败熔断（loop 路由层集成）
//    · I 组 防线拦截也落审计（blocked_by=accessibility_denied + 参数可回溯）
//    · J 组 权限预检分派（截屏查屏幕录制、动作查辅助功能、预检零截屏）
//    · AX-C 组 校正链回落规则（role 黑白名单/巨型 frame/越屏/零尺寸/开关）
//    · AX-D 组 点击落点=frame 中心 + 审计命中方式
//    · AX-E 组 element_locate 只读查询（hit=False 是正常答案非错误）
//    · AG-F 组 cu_macro_replay 权限预检（屏幕录制缺失不误伤）
//
//  ⛔ 测试铁律同 Python：绝不真实点击/输入/截屏——全部系统副作用经 FakeCUAdapter
//  记录型桩断言「该不该执行 + 参数对不对」。
//
//  ⚠️VERIFY 未翻（原因列于汇报）：
//    · test_computer_use.py A 组 tools_spec 暴露与配置默认值——W4a 路由/配置层已覆盖
//      （NativeConfigStore 默认值 test 与 loop 工具装配 test 属既有基线）。
//    · C 组真截屏体积/像素验证（C1-C6 的 PIL 侧断言）——真层 CGWindowList 直出，
//      仅编译链接验证；契约字段经假捕获层全量断言。
//    · F 组 check_capabilities（设置面板「检测权限」探测 API）——非工具执行面，
//      原生未移植该面板探测入口（W4c 范围外，汇报清单列明）。
//    · G12/G13 HID tap/事件类型裸常量——Python ctypes 裸常量层；原生用 CGEventType
//      类型化枚举直调，无裸常量可断言（类型系统即守护）。
//    · D10 的 extra{desc,app} 字段——Python authorizer 第 4 参 extra 字典；
//      原生 NativeToolAuthorizer 协议为 (tool,path,action) 三参，desc/app 未随
//      path 外另传（path 内已含全部动作参数 JSON）——已知映射偏差，汇报列明。
//

import XCTest
@testable import VetarAINative

// MARK: - 记录型假平台适配层（_StubExec/FakeAS/FakeCG 同构；⛔ 零真实副作用）

private final class FakeCUAdapter: NativeCUPlatformAdapter, @unchecked Sendable {
    var ax: Bool? = true
    var screen: Bool? = true
    var geometry: (Int, Int) = (1728, 1117)
    var frontmost: String = "Finder"
    var hit: NativeCUElementHit? = nil
    var elements: [NativeCUElementHit] = []
    var lastError = ""
    var screenshot: NativeCUScreenshot? = nil
    var captureError: Error? = nil

    private(set) var captureCalls = 0
    private(set) var geometryCalls = 0
    private(set) var frontmostCalls = 0
    private(set) var moves: [(Double, Double)] = []
    private(set) var buttons: [(down: Bool, button: String, x: Double, y: Double, clickState: Int)] = []
    private(set) var keys: [(keyCode: UInt16, down: Bool, flags: UInt64, units: [UInt16])] = []
    private(set) var hitCalls: [(Double, Double)] = []
    private(set) var elementCalls: [(String, Int)] = []

    func axTrusted() -> Bool? { ax }
    func screenCaptureAccess() -> Bool? { screen }
    func screenGeometry() -> (Int, Int) { geometryCalls += 1; return geometry }
    func captureScreenshot(maxLongEdge: Int, jpegQuality: Int) throws -> NativeCUScreenshot {
        captureCalls += 1
        if let captureError { throw captureError }
        if let screenshot { return screenshot }
        return NativeCUScreenshot(jpegData: Data(repeating: 0xAB, count: 2048),
                                  widthPx: 3456, heightPx: 2234,
                                  sentWidth: 1568, sentHeight: 1014)
    }
    func postMouseMove(x: Double, y: Double) throws { moves.append((x, y)) }
    func postMouseButton(down: Bool, button: String, x: Double, y: Double,
                         clickState: Int) throws {
        buttons.append((down, button, x, y, clickState))
    }
    func postKeyboard(keyCode: UInt16, down: Bool, flags: UInt64,
                      unicodeUnits: [UInt16]) throws {
        keys.append((keyCode, down, flags, unicodeUnits))
    }
    func hitTest(x: Double, y: Double) -> NativeCUElementHit? {
        hitCalls.append((x, y)); return hit
    }
    func appElements(app: String, depth: Int) -> [NativeCUElementHit] {
        elementCalls.append((app, depth)); return elements
    }
    func axLastError() -> String { lastError }
    func frontmostApp() -> String { frontmostCalls += 1; return frontmost }
}

// MARK: - 套件

final class NativeComputerUseTests: XCTestCase {

    private var tmp: URL!
    private var adapter: FakeCUAdapter!
    private var config: [String: JSONValue]!
    private var authzCalls: [(tool: String, path: String, action: String)] = []
    private var authzAnswer = true

    override func setUp() {
        super.setUp()
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("p2w4c_cu_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        adapter = FakeCUAdapter()
        config = [:]
        authzCalls = []
        authzAnswer = true
    }

    override func tearDown() {
        if let tmp { try? FileManager.default.removeItem(at: tmp) }
        super.tearDown()
    }

    /// 装配引擎（sleeper 置 0；授权器经记录型闭包）。
    private func makeEngine(withAuthorizer: Bool = true) -> NativeComputerUseEngine {
        let authorizer: NativeCallbackAuthorizer? = withAuthorizer
            ? NativeCallbackAuthorizer(onAuthorize: { [self] tool, path, action in
                self.authzCalls.append((tool, path, action))
                return self.authzAnswer
            })
            : nil
        return NativeComputerUseEngine(
            adapter: adapter, dataRoot: tmp,
            configProvider: { [self] in self.config },
            authorizer: authorizer,
            sleeper: { _ in })
    }

    /// 读审计日志（每行一个 JSON）。
    private func auditLines() -> [[String: JSONValue]] {
        let url = tmp.appendingPathComponent("computer_use/actions.jsonl")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            guard let d = line.data(using: .utf8),
                  case .object(let o)? = NativeJSONWriter.loads(d) else { return nil }
            return o
        }
    }

    // ══════════════════════════════════════════════════════════
    // MARK: B 组 执行层校验拒绝（test_computer_use.py test_b_executor_validation）
    // ══════════════════════════════════════════════════════════

    /// B1-B4：非法坐标（非数字/NaN/inf/None）→ bad_arg，未发任何事件
    func testB_badCoordinatesRejected() {
        let eng = makeEngine()
        let r1 = eng.mouseClick(x: .string("abc"), y: .int(100), button: "left", clicks: nil)
        XCTAssertEqual(r1["ok"]?.bool, false)
        XCTAssertTrue(r1["error"]?.string?.contains("bad_arg") ?? false, "B1 非数字→bad_arg")
        for (tag, v) in [("B2", Double.nan), ("B3", Double.infinity)] {
            let r = eng.mouseClick(x: .double(v), y: .int(100), button: "left", clicks: nil)
            XCTAssertEqual(r["ok"]?.bool, false, "\(tag) NaN/inf→拒绝")
        }
        let r4 = eng.mouseClick(x: nil, y: nil, button: "left", clicks: nil)
        XCTAssertEqual(r4["ok"]?.bool, false, "B4 None→拒绝")
        XCTAssertTrue(adapter.moves.isEmpty && adapter.buttons.isEmpty, "拒绝路径零事件")
    }

    /// B5/B6：越界坐标 → coord_out_of_range + coord_factor 换算指引
    func testB_outOfRangeCoordinateGuidance() {
        let eng = makeEngine()
        let r = eng.mouseClick(x: .int(99999), y: .int(99999), button: "left", clicks: nil)
        let err = r["error"]?.string ?? ""
        XCTAssertEqual(r["ok"]?.bool, false)
        XCTAssertTrue(err.contains("coord_out_of_range"), "B5 越界→coord_out_of_range")
        XCTAssertTrue(err.contains("coord_factor") || err.contains("换算"),
                      "B6 报错提示坐标换算（可自纠正）")
        XCTAssertTrue(adapter.buttons.isEmpty)
    }

    /// B7：非法 button → 拒绝且点明 button
    func testB_invalidButton() {
        let eng = makeEngine()
        let r = eng.mouseClick(x: .int(100), y: .int(100), button: "middle", clicks: nil)
        XCTAssertEqual(r["ok"]?.bool, false)
        XCTAssertTrue(r["error"]?.string?.contains("button") ?? false)
    }

    /// B8-B10：keyboard_type 校验（空/超长；非字符串经路由层归一为空串→bad_arg）
    func testB_keyboardTypeValidation() async {
        let eng = makeEngine()
        let r1 = eng.keyboardType(text: "")
        XCTAssertEqual(r1["ok"]?.bool, false)
        XCTAssertTrue(r1["error"]?.string?.contains("bad_arg") ?? false, "B8 空文本→bad_arg")
        // B9：Python keyboard_type(123) 非字符串→拒绝；原生路由 args["text"]?.string
        // 对 .int(123) 取不到 string → 归一 "" → bad_arg（同拒绝语义）
        let r9 = await eng.executeComputerUse("keyboard_type", args: ["text": .int(123)])
        XCTAssertEqual(r9["ok"]?.bool, false, "B9 非字符串文本→拒绝")
        XCTAssertTrue(r9["error"]?.string?.contains("bad_arg") ?? false)
        let long = String(repeating: "x", count: NativeComputerUseEngine.maxTypeChars + 1)
        let r2 = eng.keyboardType(text: long)
        let err = r2["error"]?.string ?? ""
        XCTAssertTrue(err.contains("too_long"), "B10 超长→too_long")
        XCTAssertTrue(err.contains("\(NativeComputerUseEngine.maxTypeChars)"), "B10 报错含上限")
        XCTAssertTrue(adapter.keys.isEmpty, "拒绝路径零键盘事件")
    }

    /// B11-B14：keyboard_hotkey 校验（空/未知键列支持清单/超4键/双主键）
    func testB_keyboardHotkeyValidation() {
        let eng = makeEngine()
        let r1 = eng.keyboardHotkey(keys: "")
        XCTAssertEqual(r1["ok"]?.bool, false)
        XCTAssertTrue(r1["error"]?.string?.contains("bad_arg") ?? false, "B11 空按键→bad_arg")
        let r2 = eng.keyboardHotkey(keys: "不存在的键")
        let err2 = r2["error"]?.string ?? ""
        XCTAssertTrue(err2.contains("unknown_key"), "B12 未知键→unknown_key")
        XCTAssertTrue(err2.contains("return"), "B12 列出支持的键（可自纠正）")
        let r3 = eng.keyboardHotkey(keys: "cmd+c+d+e+f")
        XCTAssertEqual(r3["ok"]?.bool, false, "B13 组合键超4个→拒绝")
        let r4 = eng.keyboardHotkey(keys: "c+d")
        XCTAssertEqual(r4["ok"]?.bool, false)
        XCTAssertTrue(r4["error"]?.string?.contains("主键") ?? false, "B14 双主键→拒绝")
        XCTAssertTrue(adapter.keys.isEmpty)
    }

    /// B15：合法按键主键均可识别（缺键会让组合键功能不可用）
    func testB_knownKeysRecognized() {
        for k in ["return", "esc", "cmd+c", "cmd+shift+4", "tab", "space", "left", "f5"] {
            let parts = k.split(separator: "+").map(String.init)
            let main = parts.last!
            let ok = NativeComputerUseEngine.keycodes[main] != nil
                || parts.allSatisfy { NativeComputerUseEngine.modFlags[$0] != nil }
            XCTAssertTrue(ok, "B15 合法按键 \(k) 的主键可识别")
        }
    }

    // ══════════════════════════════════════════════════════════
    // MARK: G 组 纯逻辑（test_g_pure_logic；⛔ 零副作用）
    // ══════════════════════════════════════════════════════════

    /// G1-G5：UTF-16 码元拆分（BMP 逐字/emoji 代理对/混合保序/往返无损）
    func testG_utf16Units() {
        XCTAssertEqual(NativeComputerUseEngine.toUTF16Units("a测."),
                       [0x61, 0x6D4B, 0x2E], "G1 BMP 逐字映射")
        let emoji = NativeComputerUseEngine.toUTF16Units("🎉")
        XCTAssertEqual(emoji.count, 2, "G2 emoji 拆 2 码元")
        XCTAssertEqual(emoji[0], 0xD83C); XCTAssertEqual(emoji[1], 0xDF89)
        XCTAssertTrue((0xD800...0xDBFF).contains(emoji[0])
                      && (0xDC00...0xDFFF).contains(emoji[1]), "G3 代理对范围合法")
        XCTAssertEqual(NativeComputerUseEngine.toUTF16Units("a🎉b"),
                       [0x61, 0xD83C, 0xDF89, 0x62], "G4 混合保序")
        // G5 往返无损：utf16 码元序列直接还原（代理对由系统合并）
        func decode(_ units: [UInt16]) -> String {
            String(utf16CodeUnits: units, count: units.count)
        }
        for t in ["测试ABC123", "你好，世界！", "🎉emoji", "𝕏数学符号", "a\tb\nc", "【】《》；："] {
            XCTAssertEqual(decode(NativeComputerUseEngine.toUTF16Units(t)), t,
                           "G5 UTF-16 往返无损：\(t)")
        }
    }

    /// G6/G7：safe_num 只收有限数字（拒绝 NaN/inf/None/非法字符串/容器）
    func testG_safeNum() {
        XCTAssertEqual(NativeComputerUseEngine.safeNum(.double(640.5)), 640.5)
        XCTAssertEqual(NativeComputerUseEngine.safeNum(.string("100")), 100.0, "G6 数字串通过")
        let bad: [JSONValue?] = [.double(.nan), .double(.infinity), .double(-.infinity),
                                 nil, .string("abc"), .array([]), .object([:])]
        for v in bad {
            XCTAssertNil(NativeComputerUseEngine.safeNum(v), "G7 非法坐标被拒 \(String(describing: v))")
        }
    }

    /// G8-G11：keycode 表完整性 + 修饰键 flags（uint64/互不相同）
    func testG_keycodeTables() {
        for k in ["return", "esc", "tab", "space", "left", "right", "up", "down",
                  "c", "v", "a", "z", "0", "9", "f5", "delete"] {
            XCTAssertNotNil(NativeComputerUseEngine.keycodes[k], "G8 常用键 \(k) 有 keycode")
        }
        for m in ["cmd", "shift", "option", "ctrl"] {
            XCTAssertNotNil(NativeComputerUseEngine.keycodes[m], "G9 \(m) 有 keycode")
            XCTAssertGreaterThan(NativeComputerUseEngine.modFlags[m] ?? 0, 0, "G9 \(m) 有 flags")
        }
        var all: UInt64 = 0
        for m in ["cmd", "shift", "option", "ctrl", "fn"] {
            all |= NativeComputerUseEngine.modFlags[m] ?? 0
        }
        XCTAssertGreaterThan(all, 0, "G10 修饰键全开仍在 uint64 内")
        let distinct = Set(["cmd", "shift", "option", "ctrl", "fn"]
            .compactMap { NativeComputerUseEngine.modFlags[$0] })
        XCTAssertEqual(distinct.count, 5, "G11 修饰键 flags 各不相同")
    }

    /// G14：屏幕几何会话内缓存（第二次不再调系统）
    func testG_geometryCache() {
        let eng = makeEngine()
        let g1 = eng.screenGeometry()
        let g2 = eng.screenGeometry()
        XCTAssertEqual(g1.0, g2.0); XCTAssertEqual(g1.1, g2.1)
        XCTAssertEqual(adapter.geometryCalls, 1, "G14 几何只读一次（缓存生效）")
        XCTAssertGreaterThan(g1.0, 0); XCTAssertGreaterThan(g1.1, 0)
    }
}


// MARK: - C/D/E/H/I/J 组（路由防线与截屏契约）

extension NativeComputerUseTests {

    // ══════════════════════════════════════════════════════════
    // MARK: C 组 截屏契约与 Retina 换算（test_c_screenshot_and_scale；假捕获层）
    // ══════════════════════════════════════════════════════════

    /// C2-C12：截屏结果契约 + coord_factor 换算正确性 + 防线5 审计落盘
    func testC_screenshotContractAndCoordFactor() {
        let eng = makeEngine()
        let r = eng.takeScreenshot()
        XCTAssertEqual(r["ok"]?.bool, true, "C1 截屏成功（假层）")
        XCTAssertGreaterThan(r["image_base64"]?.string?.count ?? 0, 1000,
                             "C2 返回图片 base64")
        XCTAssertEqual(r["mime"]?.string, "image/jpeg", "C3 mime=image/jpeg")
        XCTAssertEqual(r["_kind"]?.string, "image", "C4 _kind=image（视觉入流）")
        let sw = r["width_sent"]?.int ?? 0, sh = r["height_sent"]?.int ?? 0
        XCTAssertLessThanOrEqual(max(sw, sh), Int64(NativeComputerUseEngine.screenshotLongEdge),
                                 "C5 长边 ≤1568")
        XCTAssertEqual(r["width_px"]?.int, 3456); XCTAssertEqual(r["height_px"]?.int, 2234)
        XCTAssertEqual(r["width_points"]?.int, 1728); XCTAssertEqual(r["height_points"]?.int, 1117)
        XCTAssertEqual(r["scale"]?.double ?? 0, 2.0, accuracy: 0.001, "Retina=像素/逻辑点")
        guard let cf = r["coord_factor"]?.double else {
            return XCTFail("C7 必须返回 coord_factor")
        }
        XCTAssertGreaterThan(cf, 0, "C7 coord_factor>0")
        // C8/C9：换算正确性是成败关键（1728/1568≈1.102041；用倒数会系统性偏一倍）
        let W = 1728.0, H = 1117.0
        XCTAssertEqual(Double(sw) / 2 * cf, W / 2, accuracy: 15, "C8 中心点换算")
        XCTAssertEqual(Double(sh) / 2 * cf, H / 2, accuracy: 15, "C8 中心点换算")
        for (sx, sy, ex, ey) in [(0.0, 0.0, 0.0, 0.0), (Double(sw) - 1, 0, W - 1, 0),
                                 (0, Double(sh) - 1, 0, H - 1),
                                 (Double(sw) - 1, Double(sh) - 1, W - 1, H - 1)] {
            XCTAssertEqual(sx * cf, ex, accuracy: 15, "C9 四角换算")
            XCTAssertEqual(sy * cf, ey, accuracy: 15, "C9 四角换算")
        }
        XCTAssertTrue(abs(cf - 1 / cf) > 0.05 || abs(cf - 1.0) < 0.01,
                      "C10 确认不是倒数写反")
        XCTAssertTrue(r["content"]?.string?.contains("coord_factor") ?? false,
                      "C11 content 告知模型换算方式")
        // C12 防线5：截屏动作落审计
        let acts = auditLines().compactMap { $0["action"]?.string }
        XCTAssertTrue(acts.contains("screenshot"), "C12 截屏已写 actions.jsonl")
    }

    /// C1 变体：截屏失败 → 「截屏失败：…」+ 屏幕录制指引（可读原因）
    func testC_screenshotFailureGuidance() {
        adapter.captureError = NativeCUPlatformError.captureFailed("模拟无权限")
        let eng = makeEngine()
        let r = eng.takeScreenshot()
        XCTAssertEqual(r["ok"]?.bool, false)
        XCTAssertTrue(r["error"]?.string?.contains("屏幕录制") ?? false,
                      "失败给出权限引导（防线1 精神）")
    }

    // ══════════════════════════════════════════════════════════
    // MARK: D 组 路由层防线（test_d_routing_defenses；执行器桩化零真实操作）
    // ══════════════════════════════════════════════════════════

    /// D3/D4：防线4 白名单不命中 → app_not_allowed 逐字前缀，执行器绝未被调用
    func testD_whitelistMissRejected() async {
        adapter.frontmost = "Safari"
        config = ["computer_use_app_whitelist": .array([.string("Finder")]),
                  "computer_use_confirm_each": .bool(true)]
        let eng = makeEngine()
        let r = await eng.executeComputerUse("mouse_click",
                                             args: ["x": .int(10), "y": .int(10)])
        let err = r["error"]?.string ?? ""
        XCTAssertEqual(r["ok"]?.bool, false)
        XCTAssertTrue(err.contains("app_not_allowed"), "D3 白名单不命中→app_not_allowed")
        XCTAssertTrue(err.contains("当前前台应用「Safari」不在允许操作的白名单内")
                      && err.contains("白名单：Finder"), "D3 拒绝文案逐字（前台名+名单）")
        XCTAssertTrue(adapter.moves.isEmpty && adapter.buttons.isEmpty,
                      "D4 白名单拒绝时未执行点击")
        XCTAssertTrue(authzCalls.isEmpty, "白名单拦截在弹窗之前")
    }

    /// D5/D6：白名单命中 + 每步确认开 + 无授权通道 → computer_use_denied，未执行
    func testD_confirmRequiredButNoChannel() async {
        config = ["computer_use_app_whitelist": .array([.string("Finder")]),
                  "computer_use_confirm_each": .bool(true)]
        let eng = makeEngine(withAuthorizer: false)
        let r = await eng.executeComputerUse("mouse_click",
                                             args: ["x": .int(10), "y": .int(10)])
        let err = r["error"]?.string ?? ""
        XCTAssertEqual(r["ok"]?.bool, false)
        XCTAssertTrue(err.contains("computer_use_denied"), "D5 无授权通道→computer_use_denied")
        XCTAssertTrue(err.contains("「点击屏幕」需用户逐步确认"), "D5 文案含动作描述")
        XCTAssertTrue(adapter.buttons.isEmpty, "D6 无授权通道时未执行点击")
    }

    /// D7-D10：用户拒绝 → denied_by_user + 禁止重试 + 执行器零调用 + 确认请求契约
    func testD_userDenied() async {
        config = ["computer_use_app_whitelist": .array([.string("Finder")]),
                  "computer_use_confirm_each": .bool(true)]
        authzAnswer = false
        let eng = makeEngine()
        let r = await eng.executeComputerUse("mouse_click",
                                             args: ["x": .int(10), "y": .int(10)])
        let err = r["error"]?.string ?? ""
        XCTAssertEqual(r["ok"]?.bool, false)
        XCTAssertTrue(err.contains("denied_by_user"), "D7 用户拒绝→denied_by_user")
        XCTAssertTrue(err.contains("不要再重试"), "D8 拒绝时禁止重试")
        XCTAssertTrue(adapter.buttons.isEmpty, "D9 拒绝→执行器绝未被调用")
        // D10 确认请求契约：tool/action 逐字；path 携带动作参数 JSON
        // （Python extra{desc,args,app} 的第 4 参在原生协议归并入 path——已知映射偏差）
        XCTAssertEqual(authzCalls.count, 1)
        XCTAssertEqual(authzCalls[0].tool, "computer_use:mouse_click")
        XCTAssertEqual(authzCalls[0].action, "computer_use")
        let detail = authzCalls[0].path.data(using: .utf8)
            .flatMap { NativeJSONWriter.loads($0) }?.object
        XCTAssertEqual(detail?["x"]?.int, 10, "D10 确认请求携带真实参数")
        XCTAssertEqual(detail?["y"]?.int, 10)
    }

    /// D11-D14：用户同意 → 执行成功，只弹一次，参数正确传给事件层，提示重新截屏
    func testD_userApprovedExecutesOnce() async {
        config = ["computer_use_confirm_each": .bool(true)]
        let eng = makeEngine()
        let r = await eng.executeComputerUse("mouse_click",
                                             args: ["x": .double(12.5), "y": .int(30),
                                                    "button": .string("right"),
                                                    "clicks": .int(2)])
        XCTAssertEqual(r["ok"]?.bool, true, "D11 同意→执行成功")
        XCTAssertEqual(authzCalls.count, 1, "D12 同意路径只弹一次确认")
        // D13 参数正确传到事件层：move + down/up×2（clickState 1,1,2,2 双击语义）
        XCTAssertEqual(adapter.moves.count, 1)
        XCTAssertEqual(adapter.moves[0].0, 12.5); XCTAssertEqual(adapter.moves[0].1, 30)
        XCTAssertEqual(adapter.buttons.map { $0.clickState }, [1, 1, 2, 2],
                       "D13 双击第二次带 clickState=2")
        XCTAssertTrue(adapter.buttons.allSatisfy { $0.button == "right"
                                                   && $0.x == 12.5 && $0.y == 30 },
                      "D13 button/坐标透传")
        XCTAssertEqual(adapter.buttons.map { $0.down }, [true, false, true, false])
        XCTAssertTrue(r["hint"]?.string?.contains("screen_view") ?? false,
                      "D14 操作后提示重新截屏核对")
    }

    /// D15：关闭每步确认 → 不弹窗直接执行（用户显式放权）
    func testD_confirmOffExecutesDirectly() async {
        config = ["computer_use_confirm_each": .bool(false)]
        let eng = makeEngine()
        let r = await eng.executeComputerUse("keyboard_hotkey",
                                             args: ["keys": .string("cmd+c")])
        XCTAssertEqual(r["ok"]?.bool, true)
        XCTAssertTrue(authzCalls.isEmpty, "D15 关确认→零弹窗")
        XCTAssertFalse(adapter.keys.isEmpty, "D15 直接执行")
    }

    /// D16/D17 + D20/D21：screen_view / element_locate 只读 → 不弹确认
    func testD_readOnlyNoConfirm() async {
        config = ["computer_use_confirm_each": .bool(true)]
        let eng = makeEngine()
        let r1 = await eng.executeComputerUse("screen_view", args: [:])
        XCTAssertEqual(r1["ok"]?.bool, true, "D17 截屏执行成功")
        XCTAssertTrue(authzCalls.isEmpty, "D16 截屏只读→不弹确认")
        let r2 = await eng.executeComputerUse("element_locate",
                                              args: ["x": .double(12.5), "y": .int(30)])
        XCTAssertEqual(r2["ok"]?.bool, true, "D21 element_locate 执行成功")
        XCTAssertTrue(authzCalls.isEmpty, "D20 element_locate 只读→不弹确认")
        XCTAssertEqual(adapter.hitCalls.count, 1, "D21 坐标传给命中测试")
        XCTAssertEqual(adapter.hitCalls[0].0, 12.5); XCTAssertEqual(adapter.hitCalls[0].1, 30)
    }

    /// D18/D19：键盘输入走确认（副作用），文本正确传给事件层
    func testD_keyboardTypeConfirmed() async {
        config = ["computer_use_confirm_each": .bool(true)]
        let eng = makeEngine()
        let r = await eng.executeComputerUse("keyboard_type",
                                             args: ["text": .string("你好")])
        XCTAssertEqual(r["ok"]?.bool, true)
        XCTAssertEqual(authzCalls.count, 1, "D18 键盘输入需确认（副作用）")
        // D19 文本经 UTF-16 码元挂在 down+up 两个事件上
        let units = NativeComputerUseEngine.toUTF16Units("你好")
        XCTAssertEqual(adapter.keys.count, 2, "同一份载荷挂 down 与 up")
        XCTAssertTrue(adapter.keys.allSatisfy { $0.units == units }, "D19 文本正确传给执行器")
    }

    // ══════════════════════════════════════════════════════════
    // MARK: E 组 白名单纯逻辑（test_e_whitelist_logic；拒绝文案逐字）
    // ══════════════════════════════════════════════════════════

    func testE_whitelistLogic() {
        let eng = makeEngine()
        // E1/E2：空名单/全空串 → 不限制
        XCTAssertEqual(eng.checkWhitelist([])["ok"]?.bool, true, "E1 空名单→放行")
        XCTAssertEqual(eng.checkWhitelist(["   ", ""])["ok"]?.bool, true, "E2 全空串→放行")
        // E3-E5：命中判定（精确/大小写不敏感/子串）
        adapter.frontmost = "Finder"
        XCTAssertEqual(eng.checkWhitelist(["Finder"])["ok"]?.bool, true, "E3 精确命中")
        XCTAssertEqual(eng.checkWhitelist(["finder"])["ok"]?.bool, true, "E4 大小写不敏感")
        XCTAssertEqual(eng.checkWhitelist(["Find"])["ok"]?.bool, true, "E5 子串匹配")
        // E6/E7：不命中 → 拒绝且原因含前台名与名单 + 纠正指引（逐字）
        let r = eng.checkWhitelist(["Safari", "预览"])
        XCTAssertEqual(r["ok"]?.bool, false)
        let reason = r["reason"]?.string ?? ""
        XCTAssertEqual(reason,
                       "当前前台应用「Finder」不在允许操作的白名单内（白名单：Safari、预览），"
                       + "已拒绝操作。如需操作该应用，请到 设置 → Computer Use 把它加入白名单。",
                       "E6/E7 拒绝文案逐字（任务161 纠正指引）")
        // E8/E9：读不到前台 + 名单非空 → 保守拒绝；名单为空 → 放行
        adapter.frontmost = ""
        let r8 = eng.checkWhitelist(["Finder"])
        XCTAssertEqual(r8["ok"]?.bool, false, "E8 读不到前台+名单非空→保守拒绝")
        XCTAssertTrue(r8["reason"]?.string?.contains("无法读取当前前台应用名") ?? false)
        XCTAssertTrue(r8["reason"]?.string?.contains("已拒绝操作") ?? false)
        XCTAssertEqual(eng.checkWhitelist([])["ok"]?.bool, true, "E9 名单空→仍放行")
    }

    // ══════════════════════════════════════════════════════════
    // MARK: H 组 权限前置拦截 + 连败熔断（test_h_permission_preflight_and_circuit）
    // ══════════════════════════════════════════════════════════

    /// H1-H4：权限缺失 → accessibility_denied 直接报错，⛔ 绝不弹确认窗，零事件
    func testH_permissionDeniedBeforeConfirm() async {
        adapter.ax = false
        config = ["computer_use_app_whitelist": .array([.string("Finder")]),
                  "computer_use_confirm_each": .bool(true)]
        let eng = makeEngine()
        let r = await eng.executeComputerUse("mouse_click",
                                             args: ["x": .int(10), "y": .int(10)])
        let err = r["error"]?.string ?? ""
        XCTAssertEqual(r["ok"]?.bool, false)
        XCTAssertTrue(err.contains("accessibility_denied"), "H1 权限缺失→直接报错")
        XCTAssertTrue(authzCalls.isEmpty, "H2 ⛔权限缺失时绝不弹确认窗")
        XCTAssertTrue(adapter.moves.isEmpty && adapter.buttons.isEmpty,
                      "H4 权限缺失时执行器绝未被调用")
    }

    /// H5-H12：连败熔断（click 败 → 截屏成 → click 败 → click 熔断），熔断绝不弹窗
    func testH_circuitBreaker() async {
        adapter.ax = false          // 点击必败；截屏只查屏幕录制 → 成功
        adapter.screen = true
        config = ["computer_use_app_whitelist": .array([.string("Finder")]),
                  "computer_use_confirm_each": .bool(true)]
        let eng = makeEngine()
        let ctx = NativeComputerUseContext(authorizer: nil, executor: eng)
        var strikes: [String: Int] = [:]
        func tc(_ name: String, _ args: [String: JSONValue]) -> NativeAgentLoop.PendingToolCall {
            NativeAgentLoop.PendingToolCall(id: "c\(name)\(args.count)", name: name, args: args)
        }
        // H5 前两次点击按权限报错（尚未熔断）
        let r1 = await NativeAgentLoop.routeComputerUse(
            tc: tc("mouse_click", ["x": .int(1), "y": .int(1)]), ctx: ctx, strikes: &strikes)
        XCTAssertTrue(r1["error"]?.string?.contains("accessibility_denied") ?? false,
                      "H5 第1次按权限报错")
        // H6 截屏成功（整轮熔断归零不影响动作级计数）
        let r2 = await NativeAgentLoop.routeComputerUse(
            tc: tc("screen_view", [:]), ctx: ctx, strikes: &strikes)
        XCTAssertEqual(r2["ok"]?.bool, true, "H6 截屏成功")
        let r3 = await NativeAgentLoop.routeComputerUse(
            tc: tc("mouse_click", ["x": .int(2), "y": .int(2)]), ctx: ctx, strikes: &strikes)
        XCTAssertTrue(r3["error"]?.string?.contains("accessibility_denied") ?? false,
                      "H5 第2次按权限报错")
        // H7 第三次同动作 → 熔断
        let r4 = await NativeAgentLoop.routeComputerUse(
            tc: tc("mouse_click", ["x": .int(3), "y": .int(3)]), ctx: ctx, strikes: &strikes)
        let err4 = r4["error"]?.string ?? ""
        XCTAssertTrue(err4.contains("computer_use_circuit_open"), "H7 第3次→熔断")
        XCTAssertTrue(authzCalls.isEmpty, "H8 ⛔熔断时绝不弹确认窗")
        XCTAssertTrue(err4.contains("不要换参数重试"), "H9 熔断禁止换参数重试/绕过")
        XCTAssertTrue(err4.contains("检测权限"), "H10 熔断引导去检测权限")
        XCTAssertEqual(NativeAgentLoop.computerUseMaxStrikes, 2, "H11 熔断阈值常量=2")
        XCTAssertTrue(adapter.buttons.isEmpty, "H12 全程执行器零真实点击")
        // 熔断结算：成功清零（连败要求「连续」）
        adapter.ax = true
        strikes = [:]
        _ = await NativeAgentLoop.routeComputerUse(
            tc: tc("mouse_click", ["x": .int(9), "y": .int(9)]), ctx: ctx, strikes: &strikes)
        XCTAssertEqual(strikes["mouse_click"], 0, "成功即清零")
    }

    // ══════════════════════════════════════════════════════════
    // MARK: I 组 防线拦截也落审计（test_i_denied_writes_audit_log）
    // ══════════════════════════════════════════════════════════

    func testI_deniedWritesAuditLog() {
        adapter.ax = false
        let eng = makeEngine()
        let r1 = eng.mouseClick(x: .int(100), y: .int(200), button: "left", clicks: nil)
        let r2 = eng.keyboardType(text: "测试文本")
        let r3 = eng.keyboardHotkey(keys: "cmd+c")
        for (tag, r) in [("I1 点击", r1), ("I2 输入", r2), ("I3 按键", r3)] {
            XCTAssertEqual(r["ok"]?.bool, false, "\(tag)被防线1拦截")
            XCTAssertTrue(r["error"]?.string?.contains("accessibility_denied") ?? false)
        }
        let lines = auditLines()
        let acts = lines.compactMap { $0["action"]?.string }
        XCTAssertEqual(acts.filter { $0 == "click" }.count, 1, "I4 失败动作全部落盘")
        XCTAssertEqual(acts.filter { $0 == "type" }.count, 1)
        XCTAssertEqual(acts.filter { $0 == "hotkey" }.count, 1)
        let blocked = lines.filter { $0["blocked_by"]?.string == "accessibility_denied" }
        XCTAssertEqual(blocked.count, 3, "I5 失败记录标注 blocked_by")
        XCTAssertTrue(blocked.contains { $0["x"]?.double == 100 && $0["y"]?.double == 200 },
                      "I6 记录含动作参数（可回溯现场）")
        XCTAssertTrue(blocked.contains { $0["keys"]?.string == "cmd+c" })
        XCTAssertTrue(blocked.contains { $0["preview"]?.string?.contains("测试文本") ?? false })
        // I7-I9：报错给出确切二进制路径 + 操作指引 + 禁止重试 + 需重启
        let e1 = r1["error"]?.string ?? ""
        let exe = (ProcessInfo.processInfo.arguments.first ?? "" as String)
        let exePath = (exe as NSString).resolvingSymlinksInPath
        XCTAssertFalse(exePath.isEmpty)
        XCTAssertTrue(e1.contains(exePath), "I7 报错含确切可执行路径")
        XCTAssertTrue(e1.contains("Cmd+Shift+G"), "I7 报错含粘贴路径指引")
        XCTAssertFalse(e1.contains("勾选 VetarAI 后重试"),
                       "I7b 不误导「勾选主程序」（原生事实：本进程本身）")
        XCTAssertTrue(e1.contains("不要再重试"), "I8 明确禁止重试")
        XCTAssertTrue(e1.contains("Cmd+Q") || e1.contains("重启"), "I9 需重启才生效")
    }

    // ══════════════════════════════════════════════════════════
    // MARK: J 组 权限预检分派（test_j_permission_preflight_dispatch）
    // ══════════════════════════════════════════════════════════

    func testJ_permissionPreflightDispatch() {
        let eng = makeEngine()
        // J1：截屏只查屏幕录制（辅助功能缺失也放行）
        adapter.ax = false; adapter.screen = true
        XCTAssertEqual(eng.checkPermissionFor("screen_view")["ok"]?.bool, true,
                       "J1 截屏只查屏幕录制")
        // J2/J3：屏幕录制缺失 → screen_capture_denied + 后果（只拍到壁纸）
        adapter.screen = false
        let r2 = eng.checkPermissionFor("screen_view")
        XCTAssertEqual(r2["ok"]?.bool, false)
        XCTAssertTrue(r2["error"]?.string?.contains("screen_capture_denied") ?? false, "J2")
        XCTAssertTrue(r2["error"]?.string?.contains("壁纸") ?? false, "J3 点明后果")
        // J4：点击/输入/按键查辅助功能
        adapter.screen = true
        for tool in ["mouse_click", "keyboard_type", "keyboard_hotkey"] {
            let r = eng.checkPermissionFor(tool)
            XCTAssertEqual(r["ok"]?.bool, false, "J4 \(tool) 辅助功能缺失→拦截")
            XCTAssertTrue(r["error"]?.string?.contains("accessibility_denied") ?? false)
        }
        // J5：两项齐备 → 放行
        adapter.ax = true
        for tool in ["mouse_click", "keyboard_type", "keyboard_hotkey"] {
            XCTAssertEqual(eng.checkPermissionFor(tool)["ok"]?.bool, true, "J5 \(tool) 放行")
        }
        // J6：⛔ 预检全程零截屏（故可在每步弹窗前调用）
        XCTAssertEqual(adapter.captureCalls, 0, "J6 预检绝不截图")
        XCTAssertTrue(adapter.moves.isEmpty && adapter.buttons.isEmpty && adapter.keys.isEmpty,
                      "J6 预检绝不发事件")
    }
}


// MARK: - AX-C/D/E 组（校正链 / 点击校正 / element_locate；test_ax_element.py 同构）

extension NativeComputerUseTests {

    // ══════════════════════════════════════════════════════════
    // MARK: AX-C 组 点击校正链回落规则（0.4.32 E2 + 0.4.33 F1 双闸门）
    // ══════════════════════════════════════════════════════════

    private func hit(_ role: String?, _ title: String?,
                     _ frame: (Double, Double, Double, Double)?) -> NativeCUElementHit {
        NativeCUElementHit(role: role, title: title, frame: frame, app: "", pid: 0)
    }

    /// C1/C1b：命中 → 取 frame 中心，method=element 且带 role/title
    func testAXC_hitCorrectsToFrameCenter() {
        let eng = makeEngine()
        adapter.hit = hit("AXButton", "存储", (100, 200, 40, 20))
        let (x, y, locate) = eng.correctXYByElement(110, 210, 1728, 1117)
        XCTAssertEqual(x, 120.0); XCTAssertEqual(y, 210.0, "C1 命中→点 frame 中心")
        XCTAssertEqual(locate["method"]?.string, "element")
        XCTAssertEqual(locate["role"]?.string, "AXButton")
        XCTAssertEqual(locate["title"]?.string, "存储", "C1b method=element 带 role/title")
    }

    /// C2：未命中 → 像素回落原坐标
    func testAXC_missFallsBack() {
        let eng = makeEngine()
        adapter.hit = nil
        let (x, y, locate) = eng.correctXYByElement(110, 210, 1728, 1117)
        XCTAssertEqual(x, 110); XCTAssertEqual(y, 210)
        XCTAssertEqual(locate["method"]?.string, "pixel_fallback", "C2 未命中→像素回落")
    }

    /// C3/C3b：开关关 → 原坐标且命中测试零调用（一期纯像素行为）
    func testAXC_switchOffSkipsHitTest() {
        config = ["cu_element_locate_enabled": .bool(false)]
        let eng = makeEngine()
        adapter.hit = hit("AXButton", "存储", (100, 200, 40, 20))
        let (x, y, _) = eng.correctXYByElement(110, 210, 1728, 1117)
        XCTAssertEqual(x, 110); XCTAssertEqual(y, 210, "C3 开关关→原坐标")
        XCTAssertTrue(adapter.hitCalls.isEmpty, "C3b 开关关→命中测试零调用")
    }

    /// C4-C8：零尺寸 frame / 中心越屏 / 无权限 / 无 frame → 一律回落（校正绝不阻断）
    func testAXC_fallbackRules() {
        let eng = makeEngine()
        adapter.hit = hit("AXButton", "x", (100, 200, 0, 20))
        var (x, y, _) = eng.correctXYByElement(110, 210, 1728, 1117)
        XCTAssertEqual(x, 110); XCTAssertEqual(y, 210, "C4 零宽 frame→回落")
        adapter.hit = hit("AXButton", "x", (2000, 2000, 40, 20))
        (x, y, _) = eng.correctXYByElement(50, 50, 1728, 1117)
        XCTAssertEqual(x, 50); XCTAssertEqual(y, 50, "C5 frame 中心越屏→回落")
        adapter.ax = false
        adapter.hit = hit("AXButton", "x", (100, 200, 40, 20))
        let callsBefore = adapter.hitCalls.count
        (x, y, _) = eng.correctXYByElement(110, 210, 1728, 1117)
        XCTAssertEqual(x, 110); XCTAssertEqual(y, 210, "C6 无权限→原坐标")
        XCTAssertEqual(adapter.hitCalls.count, callsBefore, "C6 无权限不调命中测试")
        adapter.ax = true
        adapter.hit = hit("AXButton", "x", nil)
        (x, y, _) = eng.correctXYByElement(110, 210, 1728, 1117)
        XCTAssertEqual(x, 110); XCTAssertEqual(y, 210, "C7 命中无 frame→回落")
        // C8：查询失败（nil）按未命中回落——原生协议非抛出，nil 即异常等价路径
        adapter.hit = nil
        (x, y, _) = eng.correctXYByElement(110, 210, 1728, 1117)
        XCTAssertEqual(x, 110); XCTAssertEqual(y, 210, "C8 失败→像素回落（不阻断）")
    }

    /// C9：命中 title 截断 ≤80（防大树文本爆炸）
    func testAXC_titleTruncated80() {
        let eng = makeEngine()
        adapter.hit = hit("AXButton", String(repeating: "长", count: 200), (100, 200, 40, 20))
        let (_, _, locate) = eng.correctXYByElement(110, 210, 1728, 1117)
        XCTAssertEqual(locate["method"]?.string, "element")
        XCTAssertEqual(locate["title"]?.string?.count, 80, "C9 title 截断 80")
    }

    /// C10/C11/C13/C13b：容器角色黑名单 / 未列出角色 → role_blocked 回落（带 guard 审计）
    func testAXC_roleBlocked() {
        let eng = makeEngine()
        // C10：AXGroup 全屏容器吞没（实测事故回归）
        adapter.hit = hit("AXGroup", "桌面", (0, 0, 1728, 1117))
        var (x, y, locate) = eng.correctXYByElement(110, 210, 1728, 1117)
        XCTAssertEqual(x, 110); XCTAssertEqual(y, 210, "C10 AXGroup 全屏→回落原坐标")
        XCTAssertEqual(locate["guard"]?.string, "role_blocked")
        XCTAssertNotNil(locate["frame"]?.array, "C10b guard 审计附实际 frame")
        // C11：AXWindow 小 frame 也拒（黑名单不看尺寸）
        adapter.hit = hit("AXWindow", "窗", (100, 100, 50, 50))
        (x, y, locate) = eng.correctXYByElement(110, 210, 1728, 1117)
        XCTAssertEqual(x, 110); XCTAssertEqual(y, 210)
        XCTAssertEqual(locate["guard"]?.string, "role_blocked", "C11 AXWindow→role_blocked")
        // C13：未列出角色（保守只信白名单叶子角色）
        adapter.hit = hit("AXComboBox", "下拉", (100, 100, 50, 50))
        (x, y, locate) = eng.correctXYByElement(110, 210, 1728, 1117)
        XCTAssertEqual(x, 110); XCTAssertEqual(y, 210)
        XCTAssertEqual(locate["guard"]?.string, "role_blocked", "C13 未列出角色→回落")
        // C13b：空角色同样回落
        adapter.hit = hit(nil, nil, (100, 100, 50, 50))
        (x, y, locate) = eng.correctXYByElement(110, 210, 1728, 1117)
        XCTAssertEqual(x, 110); XCTAssertEqual(y, 210)
        XCTAssertEqual(locate["guard"]?.string, "role_blocked", "C13b 空角色→回落")
    }

    /// C12/C12b：巨型 frame（超面积 10% / 超边长 480）→ oversize 回落
    func testAXC_oversize() {
        let eng = makeEngine()
        adapter.hit = hit("AXButton", "巨", (0, 0, 480, 480))
        var (x, y, locate) = eng.correctXYByElement(110, 210, 1728, 1117)
        XCTAssertEqual(x, 110); XCTAssertEqual(y, 210, "C12 480×480>屏10%→回落")
        XCTAssertEqual(locate["guard"]?.string, "oversize")
        adapter.hit = hit("AXButton", "长", (0, 0, 1000, 100))
        (x, y, locate) = eng.correctXYByElement(110, 210, 1728, 1117)
        XCTAssertEqual(x, 110); XCTAssertEqual(y, 210, "C12b 边长1000>480→回落")
        XCTAssertEqual(locate["guard"]?.string, "oversize")
    }

    /// C14/C14b：白名单叶子角色正常尺寸 → 正常校正
    func testAXC_normalCorrection() {
        let eng = makeEngine()
        adapter.hit = hit("AXIcon", "图标", (100, 200, 64, 64))
        var (x, y, locate) = eng.correctXYByElement(110, 210, 1728, 1117)
        XCTAssertEqual(x, 132); XCTAssertEqual(y, 232, "C14 AXIcon 64×64→校正 frame 中心")
        XCTAssertEqual(locate["method"]?.string, "element")
        adapter.hit = hit("AXButton", "界", (0, 0, 480, 400))
        (x, y, locate) = eng.correctXYByElement(110, 210, 1728, 1117)
        XCTAssertEqual(x, 240); XCTAssertEqual(y, 200, "C14b 480×400≤屏10%→正常校正")
        XCTAssertEqual(locate["method"]?.string, "element")
    }

    // ══════════════════════════════════════════════════════════
    // MARK: AX-D 组 点击落点=frame 中心（审计命中方式随点击落盘）
    // ══════════════════════════════════════════════════════════

    /// D1：点击成功且落点=frame 中心（不是模型给的近似坐标）+ locate=element + 审计
    func testAXD_clickLandsOnFrameCenter() {
        let eng = makeEngine()
        adapter.hit = hit("AXButton", "存储", (100, 200, 40, 20))
        let r = eng.mouseClick(x: .int(110), y: .int(210), button: "left", clicks: nil)
        XCTAssertEqual(r["ok"]?.bool, true, "D1 点击成功（假层）")
        XCTAssertEqual(adapter.buttons.count, 2, "down/up 各一")
        XCTAssertEqual(adapter.buttons[0].x, 120.0); XCTAssertEqual(adapter.buttons[0].y, 210.0,
                       "D1b ⛔点击落点=frame 中心")
        XCTAssertEqual(r["locate"]?.object?["method"]?.string, "element", "D1c locate=element")
        let rec = auditLines().last
        XCTAssertEqual(rec?["method"]?.string, "element", "D1d 审计命中方式 element")
        XCTAssertEqual(rec?["role"]?.string, "AXButton")
        XCTAssertEqual(rec?["title"]?.string, "存储")
    }

    /// D2/D2b：未命中 → 点击原坐标 + 审计 pixel_fallback
    func testAXD_clickMissFallsBack() {
        let eng = makeEngine()
        adapter.hit = nil
        let r = eng.mouseClick(x: .int(110), y: .int(210), button: "left", clicks: nil)
        XCTAssertEqual(r["ok"]?.bool, true)
        XCTAssertEqual(adapter.buttons[0].x, 110); XCTAssertEqual(adapter.buttons[0].y, 210,
                       "D2 未命中→点击原坐标")
        XCTAssertEqual(auditLines().last?["method"]?.string, "pixel_fallback", "D2b 审计回落")
    }

    /// D3：开关关 → 原坐标且命中测试零调用
    func testAXD_clickSwitchOff() {
        config = ["cu_element_locate_enabled": .bool(false)]
        let eng = makeEngine()
        adapter.hit = hit("AXButton", "存储", (100, 200, 40, 20))
        let r = eng.mouseClick(x: .int(110), y: .int(210), button: "left", clicks: nil)
        XCTAssertEqual(r["ok"]?.bool, true)
        XCTAssertEqual(adapter.buttons[0].x, 110, "D3 开关关→原坐标")
        XCTAssertTrue(adapter.hitCalls.isEmpty, "D3 命中测试零调用")
    }

    /// D5/D5b：容器命中 → 点击落原坐标（不拽到容器中心）+ 审计 guard
    func testAXD_containerNotDragged() {
        let eng = makeEngine()
        adapter.hit = hit("AXGroup", "桌面", (0, 0, 1728, 1117))
        let r = eng.mouseClick(x: .int(110), y: .int(210), button: "left", clicks: nil)
        XCTAssertEqual(r["ok"]?.bool, true)
        XCTAssertEqual(adapter.buttons[0].x, 110); XCTAssertEqual(adapter.buttons[0].y, 210,
                       "D5 容器命中→点击落原坐标")
        let rec = auditLines().last
        XCTAssertEqual(rec?["method"]?.string, "pixel_fallback")
        XCTAssertEqual(rec?["guard"]?.string, "role_blocked", "D5b 审计 guard=role_blocked")
        XCTAssertEqual(rec?["role"]?.string, "AXGroup")
        XCTAssertNotNil(rec?["frame"]?.array, "D5b 审计附实际 frame")
    }

    // ══════════════════════════════════════════════════════════
    // MARK: AX-E 组 element_locate 只读查询（0.4.32 E3）
    // ══════════════════════════════════════════════════════════

    /// E1/E2：非法坐标→bad_arg；无权限→accessibility_denied 含授权指引
    func testAXE_locateValidation() {
        let eng = makeEngine()
        let r1 = eng.elementLocate(x: .string("abc"), y: .int(1))
        XCTAssertEqual(r1["ok"]?.bool, false)
        XCTAssertTrue(r1["error"]?.string?.contains("bad_arg") ?? false, "E1 非法坐标→bad_arg")
        adapter.ax = false
        let r2 = eng.elementLocate(x: .int(1), y: .int(1))
        XCTAssertEqual(r2["ok"]?.bool, false)
        XCTAssertTrue(r2["error"]?.string?.contains("accessibility_denied") ?? false, "E2")
        XCTAssertTrue(r2["error"]?.string?.contains("系统设置") ?? false, "E2 含授权指引")
    }

    /// E3：未命中 → ok+hit=False（正常答案，非错误）
    func testAXE_locateMissIsNormalAnswer() {
        let eng = makeEngine()
        adapter.hit = nil
        let r = eng.elementLocate(x: .int(100), y: .int(200))
        XCTAssertEqual(r["ok"]?.bool, true, "E3 未命中不是错误")
        XCTAssertEqual(r["hit"]?.bool, false)
        XCTAssertTrue(r["content"]?.string?.contains("未命中") ?? false)
    }

    /// E4/E4b/E5：命中 → role/frame/center 齐全；title 截断 80；locate 落审计
    func testAXE_locateHit() {
        let eng = makeEngine()
        adapter.hit = NativeCUElementHit(
            role: "AXButton", title: String(repeating: "删", count: 120),
            frame: (100, 200, 40, 20), app: "备忘录", pid: 42)
        let r = eng.elementLocate(x: .int(110), y: .int(210))
        XCTAssertEqual(r["ok"]?.bool, true); XCTAssertEqual(r["hit"]?.bool, true)
        XCTAssertEqual(r["role"]?.string, "AXButton", "E4 role 字段")
        XCTAssertEqual(r["title"]?.string?.count, 80, "E4b ⛔title 截断 80")
        XCTAssertEqual(r["app"]?.string, "备忘录")
        XCTAssertEqual(r["frame"]?.array?.count, 4, "E4 frame 字段")
        XCTAssertEqual(r["center"]?.array?[0].double, 120.0, "E4 center=frame 中心")
        XCTAssertEqual(r["center"]?.array?[1].double, 210.0)
        let rec = auditLines().last
        XCTAssertEqual(rec?["action"]?.string, "locate", "E5 locate 动作落审计")
        XCTAssertEqual(rec?["hit"]?.bool, true)
        XCTAssertEqual(rec?["role"]?.string, "AXButton", "E5 审计含命中信息")
    }

    // ══════════════════════════════════════════════════════════
    // MARK: AG-F 组 cu_macro_replay 权限预检（test_cu_macro_agent.py F 组）
    // ══════════════════════════════════════════════════════════

    func testAGF_replayPreflight() {
        let eng = makeEngine()
        adapter.ax = false
        let r1 = eng.checkPermissionFor("cu_macro_replay")
        XCTAssertEqual(r1["ok"]?.bool, false, "F1 辅助功能缺失→拦截")
        XCTAssertTrue(r1["error"]?.string?.contains("accessibility_denied") ?? false)
        adapter.ax = true
        XCTAssertEqual(eng.checkPermissionFor("cu_macro_replay")["ok"]?.bool, true,
                       "F2 辅助功能已授→放行")
        adapter.screen = false
        XCTAssertEqual(eng.checkPermissionFor("cu_macro_replay")["ok"]?.bool, true,
                       "F3 屏幕录制缺失不误伤回放预检")
    }

    /// 路由兜底：未知工具名 → unknown_tool（不裸崩）
    func testRoute_unknownTool() async {
        let eng = makeEngine()
        let r = await eng.executeComputerUse("teleport", args: [:])
        XCTAssertEqual(r["ok"]?.bool, false)
        XCTAssertTrue(r["error"]?.string?.contains("unknown_tool") ?? false)
    }
}
