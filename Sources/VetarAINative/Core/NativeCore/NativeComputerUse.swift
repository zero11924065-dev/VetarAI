//
//  NativeComputerUse.swift
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

//  逐行为移植 subagent/sidecar/computer_use/executor.py（⛔ 只读行为规格源，1144 行；
//  语义分歧以 Python 源码为准）+ loop.py L1523-1770 的 CU 路由防线语义：
//    · 五道安全防线（executor.py 文件头）：
//        1) 辅助功能/屏幕录制权限预检（check_permission_for：只读权限状态位，
//           不截图、不发事件；必须在确认弹窗【之前】——0.4.11 真机事故教训）
//        2) 显式总开关（路由层：computer_use_ctx 为 nil 即拒——W4a 已实现）
//        3) 每步动作确认（computer_use_confirm_each 经 authorizer 弹窗；
//           用户拒绝 → denied_by_user 不执行；无授权通道 → computer_use_denied）
//        4) 应用白名单（check_whitelist 越界拒绝，文案逐字；截屏也校验）
//        5) 全程审计日志（<data_root>/computer_use/actions.jsonl，每动作一行 JSON；
//           拦截也落日志——0.4.11 修复：此前失败动作完全不落日志）
//    · 连败熔断（0.4.11 computer_use_strikes，≥2 次熔断不再弹窗）在 W4a loop 路由层
//    · 坐标系：截屏输出【像素】降采样（长边 ≤1568，JPEG q78）；点击用【逻辑点】；
//      coord_factor = 逻辑宽 / 发送宽（⭐ 不是 scale_down × retina——那是倒数，
//      实测偏 153 点）
//    · 参数防线：_safe_num 拒绝 NaN/inf/非数字；屏幕逻辑范围 ±20 容差越界拒绝；
//      button 仅 left/right；clicks 钳 1/2；type 上限 2000 字符分块 32；
//      hotkey ≤4 键、单主键、未知键列出支持清单
//    · 点击校正链（0.4.32 E2 + 0.4.33 F1 容器吞没双闸门）：
//      AX 命中测试取精确 frame 中心；容器角色黑名单/未列出角色/巨型 frame
//      (>480 逻辑点 或 >屏面积 10%) 一律回落原像素坐标并记 guard 原因；
//      校正绝不阻断点击（任何异常回落像素）
//    · element_locate（0.4.32 E3）：只读查询，title 截 80，未命中 ok=True+hit=False
//    · UTF-16 代理对拆分（emoji/数学符号必须拆高低代理，否则目标应用收非法字符）
//    · 热键序列：修饰键真按下抬起（flags 累加/递减），异常兜底抬起防粘滞
//    · 录制挂钩（0.4.32 P2）：动作成功后若录制中追加语义化 step（不重复 hit_test）
//
//  适配层设计（测试纪律：不真动鼠标键盘、不真截屏）：
//    NativeCUPlatformAdapter 是全部系统副作用的唯一出口；测试注入假适配层断言
//    调用参数与防线语义；NativeCoreGraphicsCUAdapter（NativeCUPlatformReal.swift）
//    直调 CoreGraphics/ApplicationServices 原生 API（CGEvent/CGWindowList/AXUIElement），
//    仅编译链接验证（对齐 Python 0.4.32 ctypes 直调选型，Swift 原生更顺）。
//
//  偏差（汇报清单同步）：
//    ① 截屏机制：Python 走 /usr/sbin/screencapture 子进程 + PIL 降采样；
//       原生直调 CGWindowListCreateImage + CGContext 缩放 + ImageIO JPEG。
//       结果契约（coord_factor/scale/width_points 等字段）逐字段对齐。
//    ② 前台应用名：Python 走 osascript System Events（需自身权限）；
//       原生用 NSWorkspace.frontmostApplication（无额外权限弹窗），读不到 → 空串
//       → 白名单非空时按「读不到」保守拒绝（同一防线语义）。
//    ③ 权限指引文案中的「侧车二进制」口径：原生架构事件由本进程发出，
//       进程路径经 ProcessInfo 解析为当前可执行文件；文案结构逐字保留，
//       「侧车进程而非 VetarAI 主程序」一句按原生事实改写（进程身份动态解析，
//       不写死——对齐 _process_identity 的动态检测哲学）。
//

import Foundation

// ════════════════════════════════════════════════════════════
// MARK: - 平台适配层（全部系统副作用的唯一出口；测试注入假层）
// ════════════════════════════════════════════════════════════

/// AX 命中/枚举的元素描述（ax_element._describe 同构）。
public struct NativeCUElementHit: Sendable, Equatable {
    public var role: String?
    public var title: String?
    /// (x, y, w, h) 逻辑点；缺失 → nil。
    public var frame: (Double, Double, Double, Double)?
    public var app: String
    public var pid: Int32
    public init(role: String? = nil, title: String? = nil,
                frame: (Double, Double, Double, Double)? = nil,
                app: String = "", pid: Int32 = 0) {
        self.role = role
        self.title = title
        self.frame = frame
        self.app = app
        self.pid = pid
    }
    public static func == (a: NativeCUElementHit, b: NativeCUElementHit) -> Bool {
        a.role == b.role && a.title == b.title && a.app == b.app && a.pid == b.pid
            && (a.frame == nil && b.frame == nil
                || (a.frame != nil && b.frame != nil
                    && a.frame!.0 == b.frame!.0 && a.frame!.1 == b.frame!.1
                    && a.frame!.2 == b.frame!.2 && a.frame!.3 == b.frame!.3))
    }
}

/// 截屏产物（真层 CGWindowList 直出 JPEG；already downsampled）。
public struct NativeCUScreenshot: Sendable {
    public var jpegData: Data
    public var widthPx: Int          // 原图像素宽
    public var heightPx: Int         // 原图像素高
    public var sentWidth: Int        // 降采样后（喂模型）宽
    public var sentHeight: Int
    public init(jpegData: Data, widthPx: Int, heightPx: Int,
                sentWidth: Int, sentHeight: Int) {
        self.jpegData = jpegData
        self.widthPx = widthPx
        self.heightPx = heightPx
        self.sentWidth = sentWidth
        self.sentHeight = sentHeight
    }
}

public enum NativeCUPlatformError: Error, Equatable {
    /// 截屏失败（stderr 摘要或原因；引擎转 Python「截屏失败：…」文案）。
    case captureFailed(String)
    /// 系统拒绝创建事件（CGEventCreate* 返回空；引擎转 click_failed/type_failed 文案）。
    case eventCreateFailed
}

/// 全部系统副作用的唯一出口。同步方法（CG 调用均亚毫秒）；睡眠由引擎注入的
/// sleeper 承担（测试可置 0）。
public protocol NativeCUPlatformAdapter: Sendable {
    /// AXIsProcessTrusted（读不到 → nil，不作判断依据）。
    func axTrusted() -> Bool?
    /// CGPreflightScreenCaptureAccess（只读权限状态位，不读取任何屏幕内容）。
    func screenCaptureAccess() -> Bool?
    /// 主屏逻辑点尺寸（CGDisplayPixelsWide/High；失败 → (0,0) 调用方兜底）。
    func screenGeometry() -> (Int, Int)
    /// 截全屏 → 降采样 JPEG（长边 ≤ maxLongEdge）。失败抛 captureFailed。
    func captureScreenshot(maxLongEdge: Int, jpegQuality: Int) throws -> NativeCUScreenshot
    /// 光标移动到逻辑点（kCGEventMouseMoved）。
    func postMouseMove(x: Double, y: Double) throws
    /// 鼠标键 down/up（clickState > 1 时设置 kCGMouseEventClickState——双击语义）。
    func postMouseButton(down: Bool, button: String, x: Double, y: Double,
                         clickState: Int) throws
    /// 键盘事件（unicodeUnits 非空时 CGEventKeyboardSetUnicodeString；flags≠0 时
    /// CGEventSetFlags）。keyCode 对 type 恒 0。
    func postKeyboard(keyCode: UInt16, down: Bool, flags: UInt64,
                      unicodeUnits: [UInt16]) throws
    /// AX 命中测试：逻辑点 (x,y) 处元素；无权限/无元素/任何 err → nil
    /// （失败原因写 lastError 供排障——ax_element.LAST_ERROR 同构）。
    func hitTest(x: Double, y: Double) -> NativeCUElementHit?
    /// 目标 app 的窗口 + depth≤2 层局部枚举（节点硬上限 300、窗口 ≤8、深度 ≤2）。
    /// app 未运行/无窗口/任何 err → 空列表 + lastError（回放 R4 中止判定用）。
    func appElements(app: String, depth: Int) -> [NativeCUElementHit]
    /// 最近一次 hitTest/appElements 的可读失败原因（模块级 LAST_ERROR 同构）。
    func axLastError() -> String
    /// 当前前台应用名（读不到 → 空串；白名单校验与日志用）。
    func frontmostApp() -> String
}

// ════════════════════════════════════════════════════════════
// MARK: - Computer Use 执行引擎（executor.py + loop.py CU 路由 逐行为）
// ════════════════════════════════════════════════════════════

public final class NativeComputerUseEngine: NativeComputerUseExecutor, @unchecked Sendable {

    // ── 协议常量（executor.py L70-75，非用户可配）──
    public static let screenshotLongEdge = 1568    // SCREENSHOT_LONG_EDGE
    public static let screenshotJPEGQuality = 78   // SCREENSHOT_JPEG_QUALITY
    public static let maxTypeChars = 2000          // MAX_TYPE_CHARS
    public static let typeChunkChars = 32          // TYPE_CHUNK_CHARS

    // ── 0.4.33（F1）校正链「容器吞没」双闸门常量（executor.py L641-649 逐字）──
    public static let correctRoleAllow: Set<String> = [
        "AXButton", "AXImage", "AXCell", "AXCheckBox", "AXRadioButton",
        "AXMenuItem", "AXMenuBarItem", "AXLink", "AXTextField", "AXTextArea",
        "AXStaticText", "AXTab", "AXRow", "AXOutlineRow", "AXDockItem", "AXIcon",
    ]
    public static let correctRoleBlock: Set<String> = [
        "AXGroup", "AXWindow", "AXSplitGroup", "AXScrollArea", "AXWebArea",
        "AXToolbar", "AXMenuBar", "AXApplication", "AXUnknown",
    ]
    public static let correctMaxDim = 480.0        // _CORRECT_MAX_DIM
    public static let correctMaxAreaRatio = 0.10   // _CORRECT_MAX_AREA_RATIO

    // ── 常用按键的虚拟键码（executor.py _KEYCODES 逐字；ANSI layout）──
    public static let keycodes: [String: UInt16] = [
        "return": 36, "enter": 36, "tab": 48, "space": 49, "delete": 51,
        "backspace": 51, "escape": 53, "esc": 53, "left": 123, "right": 124,
        "down": 125, "up": 126, "home": 115, "end": 119, "pageup": 116,
        "pagedown": 121, "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96,
        "f6": 97, "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103,
        "f12": 111,
        "cmd": 55, "command": 55, "meta": 55, "shift": 56, "capslock": 57,
        "option": 58, "alt": 58, "ctrl": 59, "control": 59, "fn": 63,
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8,
        "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45,
        "m": 46,
        "0": 29, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "7": 26,
        "8": 28, "9": 25,
    ]
    /// _MOD_FLAGS（CGEventFlags 掩码值逐字）。
    public static let modFlags: [String: UInt64] = [
        "cmd": 1048576, "command": 1048576, "meta": 1048576,
        "shift": 131072, "option": 524288, "alt": 524288,
        "ctrl": 262144, "control": 262144, "fn": 8388608,
    ]
    /// _CODE_TO_MOD（修饰键 keycode → 名字）。
    public static let codeToMod: [UInt16: String] = [
        55: "cmd", 56: "shift", 58: "option", 59: "ctrl", 63: "fn",
    ]
    /// _CLICK_ACTIONS（(button, clicks) → 宏 step 动作名，回放 _CLICK_MAP 反向映射）。
    public static let clickActions: [String: String] = [
        "left|1": "click", "left|2": "double_click",
        "right|1": "right_click", "right|2": "right_click",
    ]

    private let adapter: any NativeCUPlatformAdapter
    /// P3-W4：平台层只读出口（kernel 给系统级录制器接 hitTest 探针用——与 executor
    /// 命中富化同源同一适配器实例，行为对齐 user_recorder._default_hit = ax hit_test）。
    public var platformAdapter: any NativeCUPlatformAdapter { adapter }
    private let configProvider: @Sendable () -> [String: JSONValue]
    private let authorizer: (any NativeToolAuthorizer)?
    private let logDir: URL
    private let sleeper: @Sendable (Double) -> Void   // 秒；测试可置 0
    /// 宏存储（0.4.33 R1；agent 模式录制 + P3-W4 user 模式系统级录制，见
    /// NativeCUMacro.swift 文件头与 NativeUserRecorder.swift）。
    public let macroStore: NativeCUMacroStore

    private var geometryCache: (Int, Int)?           // _GEOM_CACHE 同构
    private let geometryLock = NSLock()

    public init(adapter: any NativeCUPlatformAdapter,
                dataRoot: URL,
                configProvider: @escaping @Sendable () -> [String: JSONValue],
                authorizer: (any NativeToolAuthorizer)? = nil,
                macroStore: NativeCUMacroStore? = nil,
                sleeper: (@Sendable (Double) -> Void)? = nil) {
        self.adapter = adapter
        self.configProvider = configProvider
        self.authorizer = authorizer
        let dir = dataRoot.appendingPathComponent("computer_use", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.logDir = dir
        self.sleeper = sleeper ?? { seconds in
            if seconds > 0 { Thread.sleep(forTimeInterval: seconds) }
        }
        let store = macroStore ?? NativeCUMacroStore(dataRoot: dataRoot)
        self.macroStore = store
        // 回放执行面 = executor 现有动作链（含二期校正；整宏确认一次后不再逐步确认——
        // 0.4.33 防线取舍：逐步弹窗会让长宏变成弹窗风暴，H 组真机事故同款教训）
        store.clickExecutor = { [weak self] x, y, btn, n in
            guard let self else { return Self.disposedError() }
            return self.mouseClick(x: .double(x), y: .double(y),
                                   button: btn, clicks: .int(Int64(n)))
        }
        store.typeExecutor = { [weak self] text in
            guard let self else { return Self.disposedError() }
            return self.keyboardType(text: text)
        }
        store.hotkeyExecutor = { [weak self] keys in
            guard let self else { return Self.disposedError() }
            return self.keyboardHotkey(keys: keys)
        }
        store.elementsProvider = { [weak self] app, depth in
            self?.adapter.appElements(app: app, depth: depth) ?? []
        }
        store.axLastErrorProvider = { [weak self] in
            self?.adapter.axLastError() ?? ""
        }
    }

    private static func disposedError() -> [String: JSONValue] {
        ["ok": .bool(false), "error": .string("执行器已释放")]
    }

    private func config() -> [String: JSONValue] { configProvider() }

    static func err(_ message: String) -> [String: JSONValue] {
        ["ok": .bool(false), "error": .string(message)]
    }

    // ══════════════════════════════════════════════════════════
    // MARK: loop.py CU 路由（L1528-1629 动作组 / L1644-1770 宏组 逐行为）
    // ══════════════════════════════════════════════════════════

    /// NativeComputerUseExecutor 统一执行面。W4a loop 路由已处理：
    /// computer_use_ctx 为 nil（未启用）与连败熔断（strikes）——本方法从
    /// 「读配置 + 防线4 白名单」开始（loop.py L1551 起）。
    public func executeComputerUse(_ tool: String,
                                   args: [String: JSONValue]) async -> [String: JSONValue] {
        switch tool {
        case "screen_view", "mouse_click", "keyboard_type", "keyboard_hotkey",
             "element_locate":
            return await routeActionTool(tool, args: args)
        case "cu_macro_record", "cu_macro_replay", "cu_macro_list":
            return await routeMacroTool(tool, args: args)
        default:
            return Self.err("unknown_tool: \(tool)")
        }
    }

    /// 动作组路由（loop.py L1551-1623）：白名单 → 权限预检 → （副作用）逐步确认 → 执行。
    private func routeActionTool(_ tool: String,
                                 args: [String: JSONValue]) async -> [String: JSONValue] {
        let cfg = config()
        let whitelist = cfg["computer_use_app_whitelist"]?.stringArray ?? []
        let confirmEach = cfg["computer_use_confirm_each"]?.bool ?? true

        // 防线4：白名单校验（截屏也校验——避免在不允许的应用上窥屏）
        let wl = checkWhitelist(whitelist)
        if !(wl["ok"]?.bool ?? false) {
            return Self.err("app_not_allowed: \(wl["reason"]?.string ?? "")")
        }
        // 0.4.11 防线1 前置：权限检查必须在【确认弹窗之前】
        let perm = checkPermissionFor(tool)
        if !(perm["ok"]?.bool ?? false) {
            return Self.err(perm["error"]?.string ?? "权限未授予")
        }

        switch tool {
        case "screen_view":
            return takeScreenshot()
        case "element_locate":
            // 0.4.32（E3）：只读查询，同截屏无需逐步确认；白名单与权限已校验
            return elementLocate(x: args["x"], y: args["y"])
        default:
            // 防线3：每步确认（副作用动作）
            let desc = ["mouse_click": "点击屏幕",
                        "keyboard_type": "输入文本",
                        "keyboard_hotkey": "按下按键"][tool] ?? "操作"
            let detail = String(NativeDatabase.dumpsUTF8(.object(args)).prefix(400))
            var allowed = true
            var result: [String: JSONValue] = [:]
            if confirmEach {
                if authorizer == nil {
                    result = Self.err("computer_use_denied: 「\(desc)」需用户逐步确认，"
                        + "但当前无授权通道，已拒绝执行（不擅自操作你的电脑）。")
                    allowed = false
                } else {
                    let okU = await authorizer!.authorize(
                        tool: "computer_use:\(tool)", path: detail, action: "computer_use")
                    allowed = okU
                    if !allowed {
                        result = Self.err("denied_by_user: 用户拒绝了本次「\(desc)」操作。"
                            + "不要再重试该操作，请如实告知用户已取消，并询问下一步。")
                    }
                }
            }
            if allowed {
                switch tool {
                case "mouse_click":
                    result = mouseClick(x: args["x"], y: args["y"],
                                        button: args["button"]?.string ?? "left",
                                        clicks: args["clicks"])
                case "keyboard_type":
                    result = keyboardType(text: args["text"]?.string ?? "")
                default:
                    result = keyboardHotkey(keys: args["keys"]?.string ?? "")
                }
                // 操作后提示模型重新截屏核对（界面已变，别凭记忆继续）
                if result["ok"] == .bool(true) {
                    result["hint"] = .string("操作后界面可能已变化，"
                        + "继续下一步前请先 screen_view 重新截屏核对结果。")
                }
            }
            return result
        }
    }

    /// 宏组路由（loop.py L1657-1770）：record/list 不查白名单/权限、不弹确认；
    /// replay 走防线4+防线1+防线3【整宏一次】；宏工具不计入连败熔断（W4a 路由层已隔离）。
    private func routeMacroTool(_ tool: String,
                                args: [String: JSONValue]) async -> [String: JSONValue] {
        switch tool {
        case "cu_macro_list":
            return ["ok": .bool(true),
                    "macros": .array(macroStore.listMacros().map { $0.asJSON }),
                    "recording": .bool(macroStore.isRecording()),
                    "recording_steps": .int(Int64(macroStore.recordingSteps()))]
        case "cu_macro_record":
            let act = (args["action"]?.string ?? "").trimmingCharacters(in: .whitespaces)
                .lowercased()
            if act == "start" {
                // 0.4.33 契约原样透传：重名/已在录制 → ok=False 可读错误
                return macroStore.startRecording(name: args["name"]?.string ?? "")
            } else if act == "stop" {
                // 0 步 → {ok, saved:false, steps:0, message:"未捕获到任何动作，宏未保存"}
                return macroStore.stopRecording()
            } else {
                return Self.err("bad_arg: cu_macro_record 的 action 只能是 start/stop"
                    + "（收到 '\(act)'）")
            }
        default:
            // cu_macro_replay：先解析 id（name → id 精确匹配；同名多个 → 拒绝猜测，
            // 回放是真实键鼠，猜错后果可见）
            var mid = (args["id"]?.string ?? "").trimmingCharacters(in: .whitespaces)
            let mname = (args["name"]?.string ?? "").trimmingCharacters(in: .whitespaces)
            if mid.isEmpty && !mname.isEmpty {
                let matches = macroStore.listMacros().filter { $0.name == mname }
                if matches.count == 1 {
                    mid = matches[0].id
                } else if matches.isEmpty {
                    return Self.err("not_found: 找不到名为「\(mname)」的宏。"
                        + "请先 cu_macro_list 查看现有宏的 id/名称。")
                } else {
                    let ids = matches.prefix(5).map { $0.id }.joined(separator: "、")
                    return Self.err("ambiguous: 名为「\(mname)」的宏有 \(matches.count) 个"
                        + "（id：\(ids)）。回放会操作真实键鼠，不能猜——"
                        + "请改用 id 参数指定其中一个。")
                }
            } else if mid.isEmpty {
                return Self.err("bad_arg: cu_macro_replay 需要 id 或 name 参数"
                    + "（先 cu_macro_list 查看现有宏）")
            }
            // 防线4 白名单 + 防线1 权限预检 + 防线3 整宏一次确认
            let cfg = config()
            let whitelist = cfg["computer_use_app_whitelist"]?.stringArray ?? []
            let confirmEach = cfg["computer_use_confirm_each"]?.bool ?? true
            let wl = checkWhitelist(whitelist)
            if !(wl["ok"]?.bool ?? false) {
                return Self.err("app_not_allowed: \(wl["reason"]?.string ?? "")")
            }
            let perm = checkPermissionFor("cu_macro_replay")
            if !(perm["ok"]?.bool ?? false) {
                return Self.err(perm["error"]?.string ?? "权限未授予")
            }
            var allowed = true
            if confirmEach {
                if authorizer == nil {
                    return Self.err("computer_use_denied: 「回放宏」需用户确认，"
                        + "但当前无授权通道，已拒绝执行（不擅自操作你的电脑）。")
                }
                let detail = String(NativeDatabase.dumpsUTF8(
                    .object(["id": .string(mid)])).prefix(400))
                allowed = await authorizer!.authorize(
                    tool: "computer_use:cu_macro_replay", path: detail,
                    action: "computer_use")
                if !allowed {
                    return Self.err("denied_by_user: 用户拒绝了本次「回放宏」"
                        + "操作。不要再重试该操作，请如实告知用户"
                        + "已取消，并询问下一步。")
                }
            }
            guard allowed else { return Self.err("denied_by_user") }   // 不可达防御
            var result = macroStore.startReplay(macroId: mid)
            if result["ok"] == .bool(true) {
                // 回放异步（后台任务真实键鼠逐步执行）：告知 Agent 不要干等
                result["hint"] = .string("回放已在后台开始（真实键鼠逐步执行）。"
                    + "执行期间请勿再发起其他 CU 动作（会互相"
                    + "抢焦点）；如需确认效果，稍后 screen_view "
                    + "截屏核对实际界面状态。")
            } else {
                // 0.4.33 契约翻译：422 语义 → Agent 可读文本
                let errM = result["error"]?.string ?? ""
                if errM == "not_found" {
                    result["error"] = .string("not_found: 宏「\(mid)」不存在或已删除。"
                        + "请先 cu_macro_list 查看现有宏。")
                }
                // empty_macro / replay_busy 本身已是中文可读文本，原样透传
            }
            return result
        }
    }

    // ══════════════════════════════════════════════════════════
    // MARK: 防线4 白名单（executor.py check_whitelist 逐行为，文案逐字）
    // ══════════════════════════════════════════════════════════

    /// 白名单非空时校验当前前台应用是否在其中；空 = 不限制（仍受每步确认约束）。
    /// 返回 {"ok", "app", "reason"}。
    public func checkWhitelist(_ whitelist: [String]) -> [String: JSONValue] {
        // 保留用户原始输入（含大小写）用于报错展示；仅比较时小写化
        let raw = whitelist.map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let app = adapter.frontmostApp()
        if raw.isEmpty {
            return ["ok": .bool(true), "app": .string(app), "reason": .string("")]
        }
        if app.isEmpty {
            return ["ok": .bool(false), "app": .string(""),
                    "reason": .string("无法读取当前前台应用名（可能辅助功能权限未授予），"
                        + "在配置了应用白名单的情况下无法确认是否越界，已拒绝操作。")]
        }
        let low = app.lowercased()
        for w in raw {
            let lw = w.lowercased()
            if low == lw || low.hasPrefix(lw) || low.contains(lw) {
                return ["ok": .bool(true), "app": .string(app), "reason": .string("")]
            }
        }
        return ["ok": .bool(false), "app": .string(app),
                "reason": .string("当前前台应用「\(app)」不在允许操作的白名单内"
                    + "（白名单：\(raw.joined(separator: "、"))），已拒绝操作。"
                    + "如需操作该应用，请到 设置 → Computer Use 把它加入白名单。")]
    }

    // ══════════════════════════════════════════════════════════
    // MARK: 防线1 权限预检（executor.py check_permission_for 逐行为）
    // ══════════════════════════════════════════════════════════

    /// 发出事件的本进程可执行路径（_process_identity 的 exe 字段等价：
    /// 原生架构事件由本进程发出——偏差③）。
    private func processExePath() -> String {
        let exe = ProcessInfo.processInfo.arguments.first ?? ""
        return (exe as NSString).resolvingSymlinksInPath
    }

    /// _ax_denied（0.4.11）：辅助功能未授予统一报错 + 落审计（拦截也落日志）。
    private func axDenied(action: String, verb: String,
                          detail: [String: JSONValue] = [:]) -> [String: JSONValue] {
        var rec: [String: JSONValue] = ["ok": .bool(false),
                                        "blocked_by": .string("accessibility_denied")]
        for (k, v) in detail { rec[k] = v }
        audit(action, rec)
        let exe = processExePath()
        let guide = exe.isEmpty ? "" : "    \(exe)\n"
        return Self.err(
            "accessibility_denied: 辅助功能权限未授予，\(verb)会被系统静默丢弃"
            + "（看似执行成功实则无效）。\n"
            + "⚠️ macOS 按【二进制文件】授权，发出事件的是本进程本身（原生架构无侧车），"
            + "请把下面这个文件本身加入名单：\n"
            + guide
            + "操作：系统设置 → 隐私与安全性 → 辅助功能 → 点「+」→ 按 Cmd+Shift+G 粘贴上述路径 "
            + "→ 添加并勾选 → 完全退出 VetarAI（Cmd+Q）后重开（权限在进程启动时读取，"
            + "运行中修改名单不生效）。\n"
            + "不要再重试本动作，请如实告知用户需先完成授权。")
    }

    /// check_permission_for（0.4.11）：只读权限状态位，不截图、不发送任何事件。
    public func checkPermissionFor(_ tool: String) -> [String: JSONValue] {
        if tool == "screen_view" {
            // 截屏只需屏幕录制权限（不需要辅助功能）
            if adapter.screenCaptureAccess() == false {
                let exe = processExePath()
                let guide = exe.isEmpty ? "" : "请把下面这个文件加入名单：\n    \(exe)\n"
                return Self.err(
                    "screen_capture_denied: 屏幕录制权限未授予，截屏不会报错但只会拍到桌面壁纸"
                    + "（所有应用窗口被系统遮蔽），你将看不到任何界面元素。\n"
                    + guide
                    + "操作：系统设置 → 隐私与安全性 → 屏幕录制 → 「+」→ Cmd+Shift+G 粘贴上述路径 "
                    + "→ 添加并勾选 → 完全退出 VetarAI（Cmd+Q）后重开。\n"
                    + "不要再重试截屏，请如实告知用户需先完成授权。")
            }
            return ["ok": .bool(true), "error": .string("")]
        }
        // 点击/输入/按键/回放/查询：需辅助功能权限（缺它时 CGEventPost 被静默丢弃）
        if adapter.axTrusted() == false {
            let verb = ["mouse_click": "点击", "keyboard_type": "输入",
                        "keyboard_hotkey": "按键", "element_locate": "查询元素",
                        "cu_macro_replay": "操作"][tool] ?? "操作"
            return axDenied(action: tool, verb: verb)
        }
        return ["ok": .bool(true), "error": .string("")]
    }

    // ══════════════════════════════════════════════════════════
    // MARK: 防线5 全程审计（executor.py _audit 逐行为）
    // ══════════════════════════════════════════════════════════

    /// 每个动作落盘一行 JSON（{"ts","action",**detail}）；写失败绝不影响动作本身。
    public func audit(_ action: String, _ detail: [String: JSONValue]) {
        var rec = detail
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
        rec["ts"] = .string(fmt.string(from: Date()))
        rec["action"] = .string(action)
        let line = NativeDatabase.dumpsUTF8(.object(rec)) + "\n"
        guard let data = line.data(using: .utf8) else { return }
        let url = logDir.appendingPathComponent("actions.jsonl")
        if FileManager.default.fileExists(atPath: url.path),
           let h = try? FileHandle(forWritingTo: url) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }

    // ══════════════════════════════════════════════════════════
    // MARK: 屏幕几何（executor.py _screen_geometry；会话内缓存）
    // ══════════════════════════════════════════════════════════

    /// 主屏 (逻辑宽, 逻辑高)，单位点（CGEvent 坐标系）；失败 → (0,0) 调用方兜底。
    public func screenGeometry() -> (Int, Int) {
        geometryLock.lock()
        defer { geometryLock.unlock() }
        if let g = geometryCache { return g }
        let g = adapter.screenGeometry()
        geometryCache = g
        return g
    }

    // ══════════════════════════════════════════════════════════
    // MARK: 截屏（executor.py take_screenshot 逐行为）
    // ══════════════════════════════════════════════════════════

    public func takeScreenshot() -> [String: JSONValue] {
        let shot: NativeCUScreenshot
        do {
            shot = try adapter.captureScreenshot(
                maxLongEdge: Self.screenshotLongEdge,
                jpegQuality: Self.screenshotJPEGQuality)
        } catch let e as NativeCUPlatformError {
            if case .captureFailed(let why) = e {
                return Self.err("截屏失败：\(why)。若为空白/报错，请到 系统设置 → 隐私与安全性 → "
                    + "屏幕录制 勾选 VetarAI 后重试。")
            }
            return Self.err("截屏异常：\(e)")
        } catch {
            return Self.err("截屏异常：\(type(of: error)): \(error)")
        }

        let wPx = shot.widthPx, hPx = shot.heightPx
        let outW = shot.sentWidth, outH = shot.sentHeight
        // Retina 缩放比：像素 / 逻辑点（用于把模型给的坐标换算成点击坐标）
        var (logicW, logicH) = screenGeometry()
        let retina: Double
        if logicW > 0 && logicH > 0 && logicW > 0 {
            retina = (Double(wPx) / Double(logicW) * 1000).rounded() / 1000
        } else {
            retina = 2.0   // 兜底：Apple Silicon Mac 几乎都是 2x
            logicW = Int(Double(wPx) / retina)
            logicH = Int(Double(hPx) / retina)
        }
        // coord_factor = 逻辑宽 / 发送宽（⭐ 不是 scale_down × retina——那是倒数，
        // 实测中心点偏 153 点；未降采样小屏时 factor = 1/retina 同样成立）
        let coordFactor = outW > 0
            ? (Double(logicW) / Double(outW) * 1_000_000).rounded() / 1_000_000
            : 1.0
        let b64 = shot.jpegData.base64EncodedString()
        audit("screenshot", ["px": .string("\(wPx)x\(hPx)"),
                             "sent": .string("\(outW)x\(outH)"),
                             "retina": .double(retina),
                             "coord_factor": .double(coordFactor),
                             "bytes": .int(Int64(shot.jpegData.count))])
        return [
            "ok": .bool(true), "_kind": .string("image"),
            "image_base64": .string(b64),
            "mime": .string("image/jpeg"),
            "width_px": .int(Int64(wPx)), "height_px": .int(Int64(hPx)),
            "width_sent": .int(Int64(outW)), "height_sent": .int(Int64(outH)),
            "width_points": .int(Int64(logicW)), "height_points": .int(Int64(logicH)),
            "scale": .double(retina),
            // ⭐ 调用方必须用它换算坐标：逻辑点 = 模型给的坐标 × coord_factor
            "coord_factor": .double(coordFactor),
            "size": .int(Int64(shot.jpegData.count)),
            "content": .string("[已截屏：原图 \(wPx)x\(hPx)px，发送 \(outW)x\(outH)px，"
                + "屏幕逻辑尺寸 \(logicW)x\(logicH)点。"
                + "你看到的图是缩放过的：点击前必须把图上量到的像素坐标乘以 "
                + "coord_factor=\(coordFactor) 换算成屏幕坐标，否则会点偏。"),
        ]
    }

    // ══════════════════════════════════════════════════════════
    // MARK: 参数防线（executor.py _safe_num / _to_utf16_units）
    // ══════════════════════════════════════════════════════════

    /// 坐标安全转换：只接受有限数字，拒绝 NaN/inf/字符串（防非法事件参数）。
    static func safeNum(_ v: JSONValue?) -> Double? {
        guard let v else { return nil }
        let f: Double
        switch v {
        case .int(let i): f = Double(i)
        case .double(let d): f = d
        case .bool(let b): f = b ? 1 : 0   // Python float(True)=1.0
        case .string(let s):
            guard let d = Double(s.trimmingCharacters(in: .whitespaces)) else { return nil }
            f = d
        default: return nil
        }
        if f.isNaN || f.isInfinite { return nil }
        return f
    }

    /// Python repr 近似（bad_arg 报错 {x!r}）：字符串单引号包裹，其余 dumps。
    static func pyRepr(_ v: JSONValue?) -> String {
        guard let v else { return "None" }
        if case .string(let s) = v { return "'\(s)'" }
        return NativeDatabase.dumpsUTF8(v)
    }

    /// _to_utf16_units：Python 字符串 → UTF-16 码元序列（代理对拆分；
    /// Swift String 的 utf16 视图天然已是码元序列，口径等价）。
    static func toUTF16Units(_ text: String) -> [UInt16] { Array(text.utf16) }

    // ══════════════════════════════════════════════════════════
    // MARK: 点击校正链（executor.py _correct_xy_by_element 逐行为；0.4.32 E2 + 0.4.33 F1）
    // ══════════════════════════════════════════════════════════

    /// 视觉模型给的近似坐标 → AX 命中测试取精确 frame → 命中则改点 frame 中心。
    /// 回落规则（任一条不满足都保持原坐标，绝不阻断点击）：
    ///   开关关 / 无 AX 权限 / 未命中 / frame 缺失或宽高 ≤0 / frame 中心越屏 /
    ///   容器角色黑名单 / 未列出角色 / frame 超 480 逻辑点或超屏面积 10%。
    /// 返回 (x, y, locate)；locate["method"] = "element" | "pixel_fallback"。
    func correctXYByElement(_ px: Double, _ py: Double,
                            _ lw: Int, _ lh: Int) -> (Double, Double, [String: JSONValue]) {
        var locate: [String: JSONValue] = ["method": .string("pixel_fallback")]
        guard (config()["cu_element_locate_enabled"]?.bool ?? true) else {
            return (px, py, locate)
        }
        guard adapter.axTrusted() == true else { return (px, py, locate) }
        guard let hit = adapter.hitTest(x: px, y: py),
              let frame = hit.frame else { return (px, py, locate) }
        let (fx, fy, fw, fh) = frame
        guard fw > 0 && fh > 0 else { return (px, py, locate) }   // 零尺寸 frame 无中心可点
        let cx = fx + fw / 2.0, cy = fy + fh / 2.0
        // 中心点必须落在屏内（容差同坐标校验）：frame 异常时宁可信模型给的像素坐标
        if lw > 0 && lh > 0 && (cx < -20 || cy < -20 || cx > Double(lw) + 20 || cy > Double(lh) + 20) {
            return (px, py, locate)
        }
        // ── 双闸门：容器角色 / 未列出角色 / 巨型 frame 一律回落原像素 ──
        let role = hit.role ?? ""
        func guardLocate(_ guard_: String) -> [String: JSONValue] {
            ["method": .string("pixel_fallback"), "guard": .string(guard_),
             "role": .string(String(role.prefix(40))),
             "frame": .array([fx, fy, fw, fh].map { .double(($0 * 10).rounded() / 10) })]
        }
        if Self.correctRoleBlock.contains(role) {   // 容器角色必须回落（桌面全屏 AXGroup 吞没实测事故）
            return (px, py, guardLocate("role_blocked"))
        }
        if !Self.correctRoleAllow.contains(role) {  // 未列出角色必须保守回落（只信白名单叶子角色）
            return (px, py, guardLocate("role_blocked"))
        }
        let oversize = max(fw, fh) > Self.correctMaxDim
            || (lw > 0 && lh > 0 && fw * fh > Double(lw) * Double(lh) * Self.correctMaxAreaRatio)
        if oversize {                               // 巨型 frame 必须回落（超边长/超面积防护）
            return (px, py, guardLocate("oversize"))
        }
        locate = ["method": .string("element"),
                  "role": .string(String(role.prefix(40))),
                  "title": .string(String((hit.title ?? "").prefix(80))),
                  // 0.4.32（P2）：frame/app 随命中结果带出（本次 hit_test 既有产出，
                  // 零额外 AX 调用），供宏录制落语义化 step
                  "frame": .array([fx, fy, fw, fh].map { .double(($0 * 10).rounded() / 10) }),
                  "app": .string(String(hit.app.prefix(80)))]
        return (cx, cy, locate)
    }

    // ══════════════════════════════════════════════════════════
    // MARK: 录制挂钩（executor.py _maybe_record 逐行为；⛔ 绝不抛异常）
    // ══════════════════════════════════════════════════════════

    /// 动作执行成功后追加宏步骤（仅录制中生效）。element 取本次校正链 hit_test
    /// 既有结果（⛔ 不重复 hit_test）；type/key 类 element=None、app 取 frontmost。
    private func maybeRecord(_ action: String, x: Double? = nil, y: Double? = nil,
                             locate: [String: JSONValue]? = nil,
                             payload: [String: JSONValue] = [:]) {
        guard macroStore.isRecording() else { return }   // 未录制：零开销直接返回
        var element: NativeCUMacroStore.StepElement? = nil
        var app = ""
        if let locate, locate["method"]?.string == "element" {
            var frame: [Double]? = nil
            if case .array(let f)? = locate["frame"] {
                frame = f.compactMap { $0.double ?? $0.int.map { Double($0) } }
            }
            element = NativeCUMacroStore.StepElement(
                role: locate["role"]?.string ?? "",
                title: locate["title"]?.string ?? "",
                frame: frame)
            app = locate["app"]?.string ?? ""
        }
        if app.isEmpty {
            app = adapter.frontmostApp()   // best-effort（仅录制中才调）
        }
        macroStore.recordStep(action: action, x: x, y: y, app: app,
                              element: element, payload: payload)
    }

    // ══════════════════════════════════════════════════════════
    // MARK: mouse_click（executor.py 逐行为；真实 HID 事件）
    // ══════════════════════════════════════════════════════════

    public func mouseClick(x: JSONValue?, y: JSONValue?, button: String,
                           clicks: JSONValue?) -> [String: JSONValue] {
        guard let gx = Self.safeNum(x), let gy = Self.safeNum(y) else {
            return Self.err("bad_arg: 坐标必须是数字（收到 x=\(Self.pyRepr(x)), y=\(Self.pyRepr(y)))")
        }
        // 逻辑点合理范围：屏幕尺寸 + 容差（拒绝明显越界坐标，防误操作到别处）
        let (lw, lh) = screenGeometry()
        var px = gx, py = gy
        if lw > 0 && lh > 0
            && (px < -20 || py < -20 || px > Double(lw) + 20 || py > Double(lh) + 20) {
            return Self.err(String(format:
                "coord_out_of_range: 坐标 (%.0f,%.0f) 超出屏幕逻辑范围 "
                + "%dx%d。你给的可能是【图片像素坐标】未换算——请乘以 coord_factor 再试。",
                px, py, lw, lh))
        }
        let btn = (button.isEmpty ? "left" : button).lowercased()
        guard btn == "left" || btn == "right" else {
            return Self.err("bad_arg: button 只能是 left 或 right（收到 \(Self.pyRepr(.string(button)))）")
        }
        var n = 1
        if let clicks {
            if let i = clicks.int { n = Int(i) }
            else if let d = clicks.double { n = Int(d) }
            else if let s = clicks.string,
                    let i = Int(s.trimmingCharacters(in: .whitespaces)) { n = i }
        }
        n = n >= 2 ? 2 : 1

        // 防线1：无辅助功能权限时 CGEventPost 会被系统静默丢弃（看似成功实则无效），
        // 提前拦截并给出授权路径（拦截也落审计——0.4.11）
        if adapter.axTrusted() == false {
            return axDenied(action: "click", verb: "点击", detail: [
                "x": .double((px * 10).rounded() / 10), "y": .double((py * 10).rounded() / 10),
                "button": .string(btn), "clicks": .int(Int64(n)),
            ])
        }

        // 0.4.32（E2）：元素校正——近似坐标经 AX 命中取精确 frame 中心；
        // 未命中/开关关闭/任何异常一律回落原像素坐标（校正绝不阻断点击）
        let (cx, cy, locate) = correctXYByElement(px, py, lw, lh)
        px = cx; py = cy

        do {
            // 先移动光标到目标点：部分应用要求光标已就位才响应点击（如悬停态菜单）
            try adapter.postMouseMove(x: px, y: py)
            sleeper(0.03)
            for i in 1...n {
                for down in [true, false] {
                    do {
                        try adapter.postMouseButton(down: down, button: btn,
                                                    x: px, y: py, clickState: i)
                    } catch NativeCUPlatformError.eventCreateFailed {
                        var rec: [String: JSONValue] = [
                            "x": .double(px), "y": .double(py),
                            "button": .string(btn), "clicks": .int(Int64(n)),
                            "ok": .bool(false),
                            "err": .string("CGEventCreateMouseEvent 返回空"),
                        ]
                        for (k, v) in locate { rec[k] = v }
                        audit("click", rec)
                        return Self.err("click_failed: 系统拒绝创建鼠标事件"
                            + "（CGEventCreateMouseEvent 返回空）。请确认已授予辅助功能权限。")
                    }   // 其它错误外抛 → 外层 catch 记异常（Python except 同构）
                    sleeper(0.02)
                }
                if i < n { sleeper(0.06) }
            }
        } catch {
            var rec: [String: JSONValue] = [
                "x": .double(px), "y": .double(py), "button": .string(btn),
                "clicks": .int(Int64(n)), "ok": .bool(false),
                "err": .string("\(type(of: error)): \(error)"),
            ]
            for (k, v) in locate { rec[k] = v }
            audit("click", rec)
            return Self.err("click_failed: \(type(of: error)): \(error)")
        }

        var rec: [String: JSONValue] = [
            "x": .double((px * 10).rounded() / 10), "y": .double((py * 10).rounded() / 10),
            "button": .string(btn), "clicks": .int(Int64(n)), "ok": .bool(true),
            "screen_points": .string("\(lw)x\(lh)"),
        ]
        for (k, v) in locate { rec[k] = v }
        audit("click", rec)
        // 0.4.32（P2）录制挂钩：动作成功后若录制中则追加语义化 step（不重复 hit_test）
        maybeRecord(Self.clickActions["\(btn)|\(n)"] ?? (btn == "right" ? "right_click" : "click"),
                    x: (px * 10).rounded() / 10, y: (py * 10).rounded() / 10,
                    locate: locate,
                    payload: ["button": .string(btn), "clicks": .int(Int64(n))])
        var out: [String: JSONValue] = [
            "ok": .bool(true), "action": .string("click"),
            "x": .double(px), "y": .double(py),
            "button": .string(btn), "clicks": .int(Int64(n)),
            "locate": .object(locate),
            "content": .string(String(format: "已在逻辑点 (%.0f,%.0f) %@键点击%d次", px, py, btn, n)),
            "hint": .string("操作后界面可能已变化，继续下一步前请先 screen_view 重新截屏核对结果。"),
        ]
        return out
    }

    // ══════════════════════════════════════════════════════════
    // MARK: element_locate（executor.py 逐行为；0.4.32 E3 只读查询）
    // ══════════════════════════════════════════════════════════

    public func elementLocate(x: JSONValue?, y: JSONValue?) -> [String: JSONValue] {
        guard let px = Self.safeNum(x), let py = Self.safeNum(y) else {
            return Self.err("bad_arg: 坐标必须是数字（收到 x=\(Self.pyRepr(x)), y=\(Self.pyRepr(y)))")
        }
        if adapter.axTrusted() == false {
            return axDenied(action: "locate", verb: "查询元素", detail: [
                "x": .double((px * 10).rounded() / 10), "y": .double((py * 10).rounded() / 10),
            ])
        }
        let hit = adapter.hitTest(x: px, y: py)   // 查询失败按未命中处理，绝不抛给模型
        guard let hit else {
            audit("locate", ["x": .double((px * 10).rounded() / 10),
                             "y": .double((py * 10).rounded() / 10),
                             "ok": .bool(true), "hit": .bool(false)])
            return ["ok": .bool(true), "hit": .bool(false),
                    "content": .string(String(format:
                        "坐标 (%.0f,%.0f) 未命中任何界面元素"
                        + "（可能目标应用 AX 树贫乏，属预期）。点击时请直接使用原坐标。", px, py))]
        }
        var center: [Double]? = nil
        if let frame = hit.frame, frame.2 > 0, frame.3 > 0 {
            center = [((frame.0 + frame.2 / 2.0) * 10).rounded() / 10,
                      ((frame.1 + frame.3 / 2.0) * 10).rounded() / 10]
        }
        let title = String((hit.title ?? "").prefix(80))   // ⛔ title 必须截断防爆
        let role = hit.role ?? ""
        audit("locate", ["x": .double((px * 10).rounded() / 10),
                         "y": .double((py * 10).rounded() / 10),
                         "ok": .bool(true), "hit": .bool(true),
                         "role": .string(String(role.prefix(40))), "title": .string(title)])
        var desc = "命中元素：role=\(role.isEmpty ? "未知" : role)"
        if !title.isEmpty { desc += "，title='\(title)'" }
        if let frame = hit.frame {
            desc += String(format: "，frame=(%.1f, %.1f, %.1f, %.1f)",
                           (frame.0 * 10).rounded() / 10, (frame.1 * 10).rounded() / 10,
                           (frame.2 * 10).rounded() / 10, (frame.3 * 10).rounded() / 10)
        }
        if let center {
            desc += String(format: "。点击该中心：(%.0f,%.0f)", center[0], center[1])
        }
        var out: [String: JSONValue] = [
            "ok": .bool(true), "hit": .bool(true),
            "role": .string(role), "title": .string(title),
            "app": .string(hit.app),
            "content": .string(desc),
        ]
        if let frame = hit.frame {
            out["frame"] = .array([frame.0, frame.1, frame.2, frame.3]
                .map { .double(($0 * 10).rounded() / 10) })
        } else {
            out["frame"] = .null
        }
        if let center {
            out["center"] = .array(center.map { .double($0) })
        } else {
            out["center"] = .null
        }
        return out
    }

    // ══════════════════════════════════════════════════════════
    // MARK: keyboard_type（executor.py 逐行为；UTF-16 码元分块发送）
    // ══════════════════════════════════════════════════════════

    public func keyboardType(text: String) -> [String: JSONValue] {
        if text.isEmpty {
            return Self.err("bad_arg: text 必须是非空字符串")
        }
        if text.count > Self.maxTypeChars {
            return Self.err("too_long: 单次输入上限 \(Self.maxTypeChars) 字符"
                + "（收到 \(text.count)），请分段输入")
        }
        if adapter.axTrusted() == false {
            return axDenied(action: "type", verb: "输入", detail: [
                "chars": .int(Int64(text.count)),
                "preview": .string(String(text.prefix(40))),
            ])
        }
        // 必须拆 UTF-16 代理对（Swift utf16 视图天然是码元序列——emoji/数学符号正确）
        let units = Self.toUTF16Units(text)
        var typedUnits = 0
        do {
            // 分块发送：单个事件承载过多字符时部分应用会截断
            for start in stride(from: 0, to: units.count, by: Self.typeChunkChars) {
                let chunk = Array(units[start..<min(start + Self.typeChunkChars, units.count)])
                for down in [true, false] {
                    do {
                        // 同一份 Unicode 载荷必须同时挂在 down 与 up 上（只挂 down 会丢字符）
                        try adapter.postKeyboard(keyCode: 0, down: down, flags: 0,
                                                 unicodeUnits: chunk)
                    } catch NativeCUPlatformError.eventCreateFailed {
                        return Self.err("type_failed: 系统拒绝创建键盘事件"
                            + "（CGEventCreateKeyboardEvent 返回空）。"
                            + "请确认已授予辅助功能权限。")
                    }   // 其它错误外抛 → 外层 catch（Python except 同构）
                    sleeper(0.004)
                }
                typedUnits += chunk.count
            }
        } catch {
            audit("type", ["chars": .int(Int64(text.count)),
                           "units": .int(Int64(typedUnits)),
                           "preview": .string(String(text.prefix(40))),
                           "ok": .bool(false),
                           "err": .string("\(type(of: error)): \(error)")])
            return Self.err("type_failed: \(type(of: error)): \(error)。"
                + "请确认已授予辅助功能权限，且目标输入框已获得焦点（先用 mouse_click 点它）。")
        }

        audit("type", ["chars": .int(Int64(text.count)),
                       "units": .int(Int64(typedUnits)),
                       "preview": .string(String(text.prefix(40))), "ok": .bool(true)])
        // 0.4.32（P2）录制挂钩：type 步骤直接落 payload（回放按 payload 重放）；
        // app 取当前 frontmost app，element 留 null
        maybeRecord("type", payload: ["text": .string(text)])
        return ["ok": .bool(true), "action": .string("type"),
                "chars": .int(Int64(text.count)), "units": .int(Int64(typedUnits)),
                "content": .string("已输入 \(text.count) 个字符（\(typedUnits) 个 UTF-16 码元）"),
                "hint": .string("操作后界面可能已变化，继续下一步前请先 screen_view 重新截屏核对结果。")]
    }

    // ══════════════════════════════════════════════════════════
    // MARK: keyboard_hotkey（executor.py 逐行为；修饰键真按下抬起防粘滞）
    // ══════════════════════════════════════════════════════════

    public func keyboardHotkey(keys: String) -> [String: JSONValue] {
        if keys.trimmingCharacters(in: .whitespaces).isEmpty {
            return Self.err("bad_arg: keys 必须是非空字符串（如 'cmd+c'）")
        }
        let parts = keys.components(separatedBy: "+")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
        if parts.isEmpty {
            return Self.err("bad_arg: keys 解析后为空")
        }
        if parts.count > 4 {
            return Self.err("bad_arg: 组合键最多 4 个键（收到 \(parts.count) 个）")
        }

        var mods: [String] = []
        var main: String? = nil
        for p in parts {
            if Self.modFlags[p] != nil && !["cmd", "command", "meta"].contains(p) {
                mods.append(p)
            } else if Self.modFlags[p] != nil {
                mods.append("cmd")
            } else {
                if let main {
                    return Self.err("bad_arg: 组合键只能有一个主键（收到 '\(main)' 与 '\(p)'）")
                }
                main = p
            }
        }
        var mainKey = main
        if mainKey == nil {
            // 纯修饰键（如只按 shift）：单独按下抬起
            mainKey = mods.isEmpty ? parts[0] : mods.removeLast()
        }
        guard let code = Self.keycodes[mainKey!] else {
            let supported = Self.keycodes.keys.filter { Self.modFlags[$0] == nil }.sorted()
                .joined(separator: ", ")
            return Self.err("unknown_key: 不认识按键 '\(mainKey!)'。支持的键："
                + String(supported.prefix(400)))
        }

        var flag: UInt64 = 0
        for m in mods { flag |= Self.modFlags[m] ?? 0 }

        if adapter.axTrusted() == false {
            return axDenied(action: "hotkey", verb: "按键", detail: ["keys": .string(keys)])
        }

        // ⭐ 真实硬件按键序列：修饰键也要【真的按下再抬起】，不能只设 flags 位——
        // 只设 flags 不发修饰键 keyDown 时，部分应用内部修饰键状态与事件不同步，
        // 出现"快捷键时灵时不灵"或"修饰键粘滞"（下次点击仍被当成 cmd+点击）。
        // 正确顺序：修饰键依次 down（flags 累加）→ 主键 down/up → 修饰键逆序 up（flags 递减）。
        let modCodes = mods.compactMap { Self.keycodes[$0] }
        var posted: [UInt16] = []   // 已按下的修饰键，异常时用于兜底抬起（防粘滞）

        func key(_ keycode: UInt16, _ isDown: Bool, _ flags: UInt64) throws {
            try adapter.postKeyboard(keyCode: keycode, down: isDown, flags: flags,
                                     unicodeUnits: [])
        }

        var acc: UInt64 = 0
        do {
            for mc in modCodes {                    // 修饰键依次按下，flags 累加
                acc |= Self.modFlags[Self.codeToMod[mc] ?? ""] ?? 0
                do {
                    try key(mc, true, acc)
                } catch NativeCUPlatformError.eventCreateFailed {
                    return Self.err("hotkey_failed: 系统拒绝创建修饰键事件。"
                        + "请确认已授予辅助功能权限。")
                }   // 其它错误外抛 → 外层 catch 兜底抬起已按下修饰键（防粘滞）
                posted.append(mc)
                sleeper(0.012)
            }
            do {
                try key(code, true, acc)            // 主键按下
            } catch NativeCUPlatformError.eventCreateFailed {
                return Self.err("hotkey_failed: 系统拒绝创建按键事件。"
                    + "请确认已授予辅助功能权限。")
            }
            sleeper(0.02)
            try? key(code, false, acc)              // 主键抬起
            sleeper(0.012)
            for mc in posted.reversed() {           // 修饰键逆序抬起，flags 递减
                acc &= ~(Self.modFlags[Self.codeToMod[mc] ?? ""] ?? 0)
                try? key(mc, false, acc)
                sleeper(0.012)
            }
            posted = []
        } catch {
            // 兜底：把还按着的修饰键全部抬起，避免用户键盘"卡在 cmd 状态"
            for mc in posted.reversed() { try? key(mc, false, 0) }
            audit("hotkey", ["keys": .string(keys), "code": .int(Int64(code)),
                             "flag": .int(Int64(bitPattern: flag)), "ok": .bool(false),
                             "err": .string("\(type(of: error)): \(error)")])
            return Self.err("hotkey_failed: \(type(of: error)): \(error)")
        }

        audit("hotkey", ["keys": .string(keys), "code": .int(Int64(code)),
                         "flag": .int(Int64(bitPattern: flag)),
                         "mods": .array(mods.map { .string($0) }), "ok": .bool(true)])
        // 0.4.32（P2）录制挂钩：key 步骤落 payload（回放按 keys 重放）
        maybeRecord("key", payload: ["keys": .string(keys)])
        return ["ok": .bool(true), "action": .string("hotkey"), "keys": .string(keys),
                "content": .string("已按下组合键 \(keys)"),
                "hint": .string("操作后界面可能已变化，继续下一步前请先 screen_view 重新截屏核对结果。")]
    }
}

// ════════════════════════════════════════════════════════════
// MARK: - check_capabilities（GET /api/computer-use/capabilities 等价，P3-W6 翻原生）
// ════════════════════════════════════════════════════════════

/// executor.py L365-475 check_capabilities 逐行为移植（只读探测，不点击不输入）。
/// app.py L2420-2441 端点的 config 富化（enabled/confirm_each/app_whitelist 顶层键）
/// 不翻：HTTP 客户端解码 CUCapabilities 时只取 ok/problems/facts，顶层键从不消费——
/// 原生同口径（面板契约零改动）。
///
/// 原生形态适配（非规格偏差，逐条注明）：
///   · 非 macOS 分支（L372-375）不适用——原生 app 仅 macOS。
///   · screencapture/osascript 存在性检查（L377-381）不适用——原生截屏走 CG 直链
///     （NativeCUPlatformReal）、前台应用走 NSWorkspace，两工具不再被使用。
///   · CoreGraphics ctypes 加载检查（L384-397）→ 原生静态直链恒可用，facts 文案
///     相应改写（展示串，Python 原文案指向 ctypes 对原生为假）。
///   · 进程身份（L403-406）：TCC 主体 = 原生 app 自身（P3-W4 已重归属），
///     process_exe = 本进程可执行路径；签名探测改 SecCode API（替代 codesign 子进程，
///     adhoc 判据 = 无 Authority 签名链，对齐 Python "Authority=" 缺失分支）。
///   · 权限引导文案按 axDenied 既有先例改写「本进程本身（原生架构无侧车）」。
public enum NativeCUCapabilities {

    /// check_capabilities() → CUCapabilities（ok/problems/facts 三要素同构）。
    public static func check(adapter: any NativeCUPlatformAdapter) -> CUCapabilities {
        var ok = true
        var problems: [String] = []
        var facts: [String: JSONValue] = [:]

        // CoreGraphics 事件接口（原生静态直链，恒可用；Python 为 ctypes 加载检查）
        facts["coregraphics"] = .string("ok（原生直链 CoreGraphics，事件接口可用）")

        // 防线1：辅助功能权限（AXIsProcessTrusted；事件被静默丢弃的最难排查失败模式）
        let ax = adapter.axTrusted()
        if let ax { facts["accessibility_trusted"] = .bool(ax) }
        let exe = processExePath()
        facts["process_exe"] = .string(exe)
        let ident = signingIdentity()
        facts["codesign_identifier"] = .string(ident.identifier ?? "")
        if let adhoc = ident.adhoc { facts["adhoc_signed"] = .bool(adhoc) }
        if ax == false {
            ok = false
            problems.append(
                "辅助功能权限未授予——点击与输入会被系统静默丢弃（看似执行成功实则无效）。\n"
                + "⚠️ macOS 按【二进制文件】授权，发出事件的是本进程本身（原生架构无侧车），"
                + "请把下面这个文件本身加入名单：\n"
                + "    \(exe)\n"
                + "操作：系统设置 → 隐私与安全性 → 辅助功能 → 点「+」→ 按 Cmd+Shift+G 粘贴上述路径 "
                + "→ 添加并勾选 → 完全退出 VetarAI（Cmd+Q）后重开。\n"
                + "注意：添加后必须【重启应用】才生效（权限在进程启动时读取）。")
            if ident.adhoc == true {
                problems.append(
                    "本应用为 ad-hoc 签名（未做 Developer ID 签名），每次重新打包签名指纹都会变化，"
                    + "系统会把它当成「另一个程序」而让已授予的权限失效。因此每次安装新版本后，"
                    + "需要到辅助功能列表里把旧条目删掉再重新添加。")
            }
        } else if ax == nil {
            problems.append(
                "无法探测辅助功能权限（AXIsProcessTrusted 不可用）；若点击/输入无效，"
                + "请到 系统设置 → 隐私与安全性 → 辅助功能，把本应用加入名单"
                + "（确切路径见上方 process_exe）。")
        }

        // 0.4.11：屏幕录制权限探测（不能用「截图成功」推断——缺权限仍返回全分辨率图，
        // 内容被系统遮蔽成壁纸，静默失效）
        let scr = adapter.screenCaptureAccess()
        if let scr { facts["screen_capture_access"] = .bool(scr) }
        if scr == false {
            ok = false
            problems.append(
                "屏幕录制权限未授予——截屏不会报错，但只能拍到桌面壁纸，"
                + "所有应用窗口内容被系统遮蔽 → 视觉模型看到空桌面、找不到任何按钮，"
                + "Computer Use 实际不可用。\n"
                + "请把下面这个文件加入名单（同样按【二进制文件】授权）：\n"
                + "    \(exe)\n"
                + "操作：系统设置 → 隐私与安全性 → 屏幕录制 → 点「+」→ Cmd+Shift+G 粘贴上述路径 "
                + "→ 添加并勾选 → 完全退出 VetarAI（Cmd+Q）后重开。")
        } else if scr == nil {
            problems.append(
                "无法探测屏幕录制权限（CGPreflightScreenCaptureAccess 不可用）；"
                + "若 Agent 反馈「只看到桌面壁纸/找不到窗口」，请到 "
                + "系统设置 → 隐私与安全性 → 屏幕录制 加入本应用。")
        }

        // 截屏能力自检（截图本身无副作用）：screen_points/screenshot_px/retina_scale
        do {
            let shot = try adapter.captureScreenshot(maxLongEdge: 1568, jpegQuality: 78)
            let (pw, ph) = adapter.screenGeometry()
            facts["screen_points"] = .string("\(pw)x\(ph)")
            facts["screenshot_px"] = .string("\(shot.widthPx)x\(shot.heightPx)")
            if pw > 0 {
                let scale = Double(shot.widthPx) / Double(pw)
                facts["retina_scale"] = scale == scale.rounded()
                    ? .int(Int64(scale)) : .double(scale)
            }
        } catch {
            ok = false
            problems.append("截屏失败：\(error.localizedDescription)")
        }

        // 前台应用名（白名单校验需要；读不到不影响权限结论——0.4.11 口径）
        let front = adapter.frontmostApp()
        if !front.isEmpty { facts["frontmost_app"] = .string(front) }

        return CUCapabilities(ok: ok, problems: problems, facts: facts)
    }

    /// sys.executable 等价（resolvingSymlinksInPath 对齐 Python Path.resolve()）。
    private static func processExePath() -> String {
        let exe = ProcessInfo.processInfo.arguments.first ?? ""
        return (exe as NSString).resolvingSymlinksInPath
    }

    /// _process_identity 的签名段等价（SecCode 替代 codesign -dv 子进程）：
    /// identifier 取 kSecCodeInfoIdentifier；adhoc = 无 Authority 签名链
    /// （Python 判据 "adhoc" 字样 / "Authority=" 缺失的合并语义）。
    /// 探测失败 → adhoc=nil（Python except 分支同口径：不写死结论）。
    private static func signingIdentity() -> (identifier: String?, adhoc: Bool?) {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else {
            return (nil, nil)
        }
        // SecCodeCopySigningInformation 只吃 SecStaticCode——先取静态表示再读签名信息
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
              let staticCode else {
            return (nil, nil)
        }
        var infoCF: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, [], &infoCF) == errSecSuccess,
              let info = infoCF as? [String: Any] else {
            return (nil, nil)
        }
        let identifier = info[kSecCodeInfoIdentifier as String] as? String
        // codesign -dv 的 Authority= 行：签名证书链；ad-hoc 签名无 Authority → adhoc=true
        if let authorities = info["Authority"] as? [Any], !authorities.isEmpty {
            return (identifier, false)
        }
        return (identifier, true)
    }
}
