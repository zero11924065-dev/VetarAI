//
//  NativeUserRecorder.swift
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

//  逐行为移植 subagent/sidecar/computer_use/user_recorder.py（⛔ 只读行为规格源，
//  887 行；语义分歧以 Python 源码为准）：CGEventTap listen-only 系统级捕获 +
//  事件合并状态机 + 「输入监控」TCC 探针。
//    · 协议常量（L59-67）：双击窗口 0.5s/位移 5pt、拖拽阈值 >8pt、ticker 0.25s、
//      tap 起跑 3s 超时、stop join 2s 兜底
//    · 事件归并（质量核心）：连续字符聚合成一个 type step（退格/回车/特殊键/切焦点/
//      点击截断）；同点双击合并为 double_click；拖拽记为【起点单击】+ payload.drag_to
//      （取舍照 Python L593-596：不记轨迹）；cmd/ctrl+键记 hotkey；纯修饰键不记
//    · 密码防护两道闸：IsSecureEventInputEnabled 或焦点 AXSecureTextField → 整段按键
//      不记（连长度都不记，只累计 secureDropped；不落 note 标记步——note 会让回放撞
//      unknown_action 中止，丢弃本身即是防护语义）
//    · 自身过滤：frontmost 命中自身身份 → 事件不录（否则用户点宏面板的操作全进宏）；
//      只截断打字聚合、不吞并前后段
//    · 权限：listen-only tap 走「输入监控」TCC（与「辅助功能」是两项独立授权，
//      CU 执行已有的辅助功能授权不覆盖它）；CGPreflight/CGRequestListenEventAccess
//    · 生命周期：独立线程跑 CFRunLoop（tap 回调只做 CGEvent → raw → ingest），
//      0.25s ticker 做双击超时定案与硬上限自动停；stop 干净拆除
//      （tap 停用 → runloop 停止 → join 兜底 → flush 残余聚合；幂等）；
//      tap 被系统禁用（超时/输入风暴）→ 重新启用重建
//
//  适配（与 Python 的口径差，commit body 同步）：
//    ① ctypes 直调层整体不需要——Swift 原生直接调 CoreGraphics/CoreFoundation/
//       HIToolbox/AppKit（Python 选型 ctypes 是因为无 pyobjc；原生无此约束）。
//    ② frontmost 探针：Python 走 libobjc 桥 + osascript 回落（1s TTL 缓存）；
//       原生直调 NSWorkspace.frontmostApplication（W4c 平台层同款先例），
//       无头进程限制不存在，回落路径不适用。
//    ③ 自过滤集合：Python _SELF_BID_PREFIX="com.vetarai"（Electron 旧壳/侧车身份）。
//       原生 app 的 bundle id 是 ai.vetar.native——自过滤前缀扩为
//       {"com.vetarai", "ai.vetar"}（同台运行的 Electron 旧壳事件同样不录），
//       应用名集合 {"vetarai", "electron"} 与 pid==自身 两道闸不变。
//    ④ 10.15 前系统无「输入监控」TCC 符号的分支（Python 视为 granted=True）不适用：
//       原生部署目标远高于 10.15，符号恒存在。
//    ⑤ Python atexit 进程退出钩子 → Swift atexit(3) 同款登记一次。
//
//  ⛔ 真捕获属真机行为：单测一律注入假探针 + 直接喂 ingest（Python 测试同款纪律），
//  真 tap/TCC 仅编译链接验证 + 父代理真机冒烟。
//

import Foundation
import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// user 模式捕获会话（cu_macro 侧只依赖 stop 语义；测试注入假捕获）。
public protocol NativeUserCaptureSession: AnyObject, Sendable {
    /// 干净拆除 + flush 收尾聚合步骤（幂等；⛔ 调用时录制单例必须仍在，
    /// 收尾步骤经 onStep → recordStep 落入宏——顺序不可反，Python L320-322）。
    func stop()
}

public final class NativeUserRecorder: NativeUserCaptureSession, @unchecked Sendable {

    // ── 协议常量（user_recorder.py L59-67，非用户可配）──
    public static let titleMax = 80             // TITLE_MAX（element.title 截断）
    public static let roleMax = 40              // ROLE_MAX
    public static let doubleClickMaxGap = 0.5   // DOUBLE_CLICK_MAX_GAP（双击间隔上限，秒）
    public static let doubleClickMaxDist = 5.0  // DOUBLE_CLICK_MAX_DIST（双击位移上限，逻辑点）
    public static let dragMinDist = 8.0         // DRAG_MIN_DIST（按下→抬起位移超此值视为拖拽）
    public static let tickInterval = 0.25       // TICK_INTERVAL（双击超时定案 + 硬上限检查）
    public static let tapStartTimeout = 3.0     // TAP_START_TIMEOUT
    public static let joinTimeout = 2.0         // JOIN_TIMEOUT

    // ── CGEvent 常量（CGEventTypes.h；L69-84）──
    static let cgEventLeftDown = 1
    static let cgEventLeftUp = 2
    static let cgEventRightDown = 3
    static let cgEventRightUp = 4
    static let cgEventKeyDown = 10
    static let cgEventOtherDown = 25
    static let cgEventOtherUp = 26

    // CGEventFlags 修饰键位（executor._MOD_FLAGS 同源；L87）
    public static let flagShift: UInt64 = 1 << 17
    public static let flagCtrl: UInt64 = 1 << 18
    public static let flagOpt: UInt64 = 1 << 19
    public static let flagCmd: UInt64 = 1 << 20

    /// 自身应用识别（L89-91 + 适配③）：frontmost 命中 → 事件不录。
    public static let selfNames: Set<String> = ["vetarai", "electron"]
    /// 自过滤 bundle id 前缀集：com.vetarai（Python 原值，Electron 旧壳/侧车）
    /// + ai.vetar（原生自身身份 ai.vetar.native——TCC 重归属后的本进程前缀）。
    public static let selfBidPrefixes = ["com.vetarai", "ai.vetar"]

    // ── 键码表（L95-115 逐字；ANSI layout，码→字符/名）──
    /// keycode → (无 shift, 有 shift)。
    public static let charMap: [Int: (String, String)] = [
        0: ("a", "A"), 1: ("s", "S"), 2: ("d", "D"), 3: ("f", "F"), 4: ("h", "H"),
        5: ("g", "G"), 6: ("z", "Z"), 7: ("x", "X"), 8: ("c", "C"), 9: ("v", "V"),
        11: ("b", "B"), 12: ("q", "Q"), 13: ("w", "W"), 14: ("e", "E"), 15: ("r", "R"),
        16: ("y", "Y"), 17: ("t", "T"),
        18: ("1", "!"), 19: ("2", "@"), 20: ("3", "#"), 21: ("4", "$"), 22: ("6", "^"),
        23: ("5", "%"), 24: ("=", "+"), 25: ("9", "("), 26: ("7", "&"), 27: ("-", "_"),
        28: ("8", "*"), 29: ("0", ")"), 30: ("]", "}"), 33: ("[", "{"),
        31: ("o", "O"), 32: ("u", "U"), 34: ("i", "I"), 35: ("p", "P"),
        37: ("l", "L"), 38: ("j", "J"), 39: ("'", "\""), 40: ("k", "K"), 41: (";", ":"),
        42: ("\\", "|"), 43: (",", "<"), 44: ("/", "?"), 45: ("n", "N"), 46: ("m", "M"),
        47: (".", ">"), 49: (" ", " "), 50: ("`", "~"),
    ]
    /// keycode → executor.keyboard_hotkey 认得的键名。
    public static let specialKeys: [Int: String] = [
        36: "return", 48: "tab", 51: "delete", 53: "escape",
        115: "home", 119: "end", 116: "pageup", 121: "pagedown",
        123: "left", 124: "right", 125: "down", 126: "up",
        122: "f1", 120: "f2", 99: "f3", 118: "f4", 96: "f5", 97: "f6", 98: "f7",
        100: "f8", 101: "f9", 109: "f10", 103: "f11", 111: "f12",
    ]
    /// cmd/shift/caps/opt/ctrl/fn 左右（纯修饰键 down 不记）。
    public static let modifierKeycodes: Set<Int> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]

    /// _char_for：keycode → 可打印字符（无 IME text 时的 ANSI 布局映射；capslock 不处理）。
    public static func charFor(_ keycode: Int, shift: Bool) -> String? {
        guard let pair = charMap[keycode] else { return nil }
        return shift ? pair.1 : pair.0
    }

    /// _main_key_name：hotkey 主键名（可打印键取无 shift 形态，特殊键取键名）。
    public static func mainKeyName(_ keycode: Int) -> String? {
        if let pair = charMap[keycode] { return pair.0 }
        return specialKeys[keycode]
    }

    // ══════════════════════════════════════════════════════════
    // MARK: 规范化事件（tap 回调与测试共用的入口模型）
    // ══════════════════════════════════════════════════════════

    public enum RawKind: String, Sendable {
        case key
        case mouseDown = "mouse_down"
        case mouseUp = "mouse_up"
    }

    /// tap 回调产出的规范化事件（Python raw dict 同构；缺省值对齐
    /// `raw.get(...) or <default>` 的语义——0/空 走默认）。
    public struct RawEvent: Sendable {
        public var kind: RawKind
        public var ts: Double = 0              // 0 = 用 now()（Python `or self._now()` 语义）
        public var keycode: Int = 0
        public var flags: UInt64 = 0
        public var text: String = ""
        public var x: Double = 0
        public var y: Double = 0
        public var button: String = "left"
        public init(kind: RawKind, ts: Double = 0, keycode: Int = 0, flags: UInt64 = 0,
                    text: String = "", x: Double = 0, y: Double = 0, button: String = "left") {
            self.kind = kind
            self.ts = ts
            self.keycode = keycode
            self.flags = flags
            self.text = text
            self.x = x
            self.y = y
            self.button = button
        }
    }

    /// 录制器产出的宏 step（Python _emit 的 dict 同构：
    /// {action, x, y, app, element:{role,title,frame}|None, payload}）。
    public struct Step: Sendable {
        public var action: String
        public var x: Double?
        public var y: Double?
        public var app: String
        public var element: Element?
        public var payload: [String: JSONValue]
    }

    public struct Element: Sendable, Equatable {
        public var role: String
        public var title: String
        public var frame: [Double]?
        public init(role: String, title: String, frame: [Double]?) {
            self.role = role
            self.title = title
            self.frame = frame
        }
    }

    // ══════════════════════════════════════════════════════════
    // MARK: 系统探针（全注入可换；生产 = 直调 CG/AX/NSWorkspace）
    // ══════════════════════════════════════════════════════════

    public struct Probes: Sendable {
        /// → (localizedName, bundleIdentifier, pid)
        public var front: @Sendable () -> (String, String, Int32)
        /// AX 命中测试（x,y）→ 元素语义；未命中/失败 → nil（只记坐标）
        public var hit: @Sendable (Double, Double) -> NativeCUElementHit?
        /// 安全输入标志（IsSecureEventInputEnabled）→ bool|nil
        public var secure: @Sendable () -> Bool?
        /// 焦点元素是否 AXSecureTextField → bool（任何失败 → false）
        public var focusedSecure: @Sendable () -> Bool
        /// 单调秒时钟
        public var now: @Sendable () -> Double

        public init(front: @escaping @Sendable () -> (String, String, Int32),
                    hit: @escaping @Sendable (Double, Double) -> NativeCUElementHit?,
                    secure: @escaping @Sendable () -> Bool?,
                    focusedSecure: @escaping @Sendable () -> Bool,
                    now: @escaping @Sendable () -> Double) {
            self.front = front
            self.hit = hit
            self.secure = secure
            self.focusedSecure = focusedSecure
            self.now = now
        }

        /// 生产探针组（hit 由调用方注入——内核接 CU 引擎 adapter，与 executor 同源）。
        public static func system(hit: @escaping @Sendable (Double, Double) -> NativeCUElementHit?) -> Probes {
            Probes(front: { NativeUserRecorder.systemFrontmost() },
                   hit: hit,
                   secure: { NativeUserRecorder.secureInputEnabled() },
                   focusedSecure: { NativeUserRecorder.focusedIsSecure() },
                   now: { ProcessInfo.processInfo.systemUptime })
        }
    }

    /// listen_access_granted（L208-225）：「输入监控」TCC 状态（只读状态位、无隐私副作用）。
    /// true/false = 明确状态；nil = 探测不到。适配④：10.15 前无符号分支不适用（部署目标恒有）。
    public static func listenAccessGranted() -> Bool? {
        CGPreflightListenEventAccess()
    }

    /// request_listen_access（L228-247）：触发系统授权弹窗并返回弹窗后状态。
    /// ⚠️ 语义逐字：系统只弹一次；用户在弹窗点「允许」后本进程需重启才生效
    /// （TCC 按进程启动时读取）；以 preflight 复核为准。
    ///
    /// Bug6 修复（2026-09-28）：原实现直接裸调 CGRequestListenEventAccess()，
    /// 对【从未登记 TCC listen-event 需求】的进程静默无反应（不弹窗、返回 false、
    /// 系统设置名单里也没有本应用）——user 录制权限闸（NativeCUMacroStore.
    /// startRecording）在未授权时 403 先拒、永不走到建 tap，permission GET 又是
    /// 只读 preflight，进程因此永远登记不上，「请求授权」按钮点击净效果为零。
    /// 修复：先做一次最小 listen-only 探测 tap——未授权时 tapCreate 必失败，但
    /// 这次尝试让 TCC 把本进程登记进「输入监控」名单（请求弹窗与手动开关的前提），
    /// 授权竞态下 tap 建成则立即拆除并直返 true；随后再调系统请求 API。
    /// （配套必改项在打包层：Info.plist 需补 NSInputMonitoringUsageDescription，
    /// 缺该键 TCC 同样不弹窗——scripts/package_app.sh 不在本次 Sources 纪律范围。）
    public static func requestListenAccess() -> Bool {
        requestListenAccessFlow(preflight: { CGPreflightListenEventAccess() },
                                probeTap: { probeListenTapAttempt() },
                                request: { CGRequestListenEventAccess() })
    }

    /// 请求流程纯决策核（可测部分；系统调用由注入缝供给，生产 = 上方真探针）：
    ///   1. preflight 已授权 → 直返 true（幂等短路：不建探测 tap、不调请求 API，
    ///      避免多余系统调用与弹窗疲劳）；
    ///   2. 探测 tap 建成 → 已授权（含 preflight 与 tap 判定竞态），直返 true；
    ///   3. 否则调系统请求 API（弹窗与否由 TCC 决定），再以 preflight 复核为准，
    ///      复核探测不到（nil）时回落请求 API 的返回值（Python L243-245 同口径）。
    static func requestListenAccessFlow(preflight: () -> Bool?,
                                        probeTap: () -> Bool,
                                        request: () -> Bool) -> Bool {
        if preflight() == true { return true }
        if probeTap() { return true }
        let granted = request()
        let pre = preflight()
        return pre ?? granted
    }

    /// 探测/登记用最小 listen-only tap（Bug6）：建成功 = 已授权，立刻拆除不留监听
    /// （不挂 runloop source、不启用）；建失败 = 未授权，但这次尝试本身让 TCC 登记
    /// 本进程的 listen-event 需求——未登记的进程调 CGRequestListenEventAccess /
    /// IOHIDRequestAccess(kIOHIDRequestTypeListenEvent) 会静默无反应，且系统设置
    /// 「输入监控」名单里不会出现本应用（用户想手动开也无处开）。
    /// ⛔ 必须 listenOnly：listen 归「输入监控」（ListenEvent）授权域；可拦截的
    /// default tap 归「辅助功能」（PostEvent）域，登记错域不解决本问题。
    @discardableResult
    static func probeListenTapAttempt() -> Bool {
        let mask: CGEventMask = (1 << Self.cgEventKeyDown)   // 最小掩码
        let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, _, event, _ in Unmanaged.passUnretained(event) },
            userInfo: nil)
        guard let tap else { return false }
        CFMachPortInvalidate(tap)
        return true
    }

    /// _secure_input_enabled（L255-280）：系统级安全输入标志（任何 app 开启安全输入
    /// 即 true）。ctypes 加载 Carbon/HIToolbox → 原生直接链接调用。
    public static func secureInputEnabled() -> Bool? {
        IsSecureEventInputEnabled()
    }

    /// _focused_is_secure（L283-313）：焦点元素是否 AXSecureTextField。
    /// 任何失败 → false（该闸是增强，主闸是 IsSecureEventInputEnabled）。
    public static func focusedIsSecure() -> Bool {
        let sw = AXUIElementCreateSystemWide()
        var fv: CFTypeRef?
        guard AXUIElementCopyAttributeValue(sw, "AXFocusedUIElement" as CFString, &fv) == .success,
              let foc = fv, CFGetTypeID(foc) == AXUIElementGetTypeID() else { return false }
        var rv: CFTypeRef?
        guard AXUIElementCopyAttributeValue(foc as! AXUIElement, "AXRole" as CFString, &rv) == .success,
              let role = rv as? String else { return false }
        return role == "AXSecureTextField"
    }

    /// _system_frontmost（L397-414 适配②）：NSWorkspace 直读
    /// （objc 桥 + osascript 1s TTL 回落不适用）；任何失败 → ("", "", 0)。
    public static func systemFrontmost() -> (String, String, Int32) {
        guard let app = NSWorkspace.shared.frontmostApplication else { return ("", "", 0) }
        return (app.localizedName ?? "", app.bundleIdentifier ?? "", app.processIdentifier)
    }

    // ══════════════════════════════════════════════════════════
    // MARK: 录制器状态（UserRecorder.__init__ L433-469 同构）
    // ══════════════════════════════════════════════════════════

    private let onStep: @Sendable (Step) -> Void
    private let onTimeout: (@Sendable () -> Void)?
    private let maxSeconds: Double
    private let probes: Probes

    /// 待单击定案的 down 信息（双击合并窗口内）。
    private struct ClickInfo {
        var x: Double
        var y: Double
        var ts: Double
        var hit: NativeCUElementHit?
        var app: String
        var button: String
    }

    private let lock = NSRecursiveLock()       // 归并状态锁（tap 回调/ticker/stop 三方）
    private var pendingText: [String] = []
    private var pendingApp = ""
    private var pendingClick: ClickInfo?
    private var dblArmed = false               // 第二次 down 已落入双击窗口
    private var down: [String: ClickInfo] = [:]  // button → down 信息（拖拽判定）
    /// 密码防护丢弃的按键数（诊断用，不进宏）。
    public private(set) var secureDropped = 0
    /// tap 被系统禁用后重建次数（诊断）。
    public private(set) var tapReenabled = 0
    /// start 失败的可读原因（供 403/422 文案）。
    public private(set) var startError = ""

    private var t0: Double
    private var timeoutFired = false
    private var stopped = false
    private let lifeLock = NSLock()
    private let stopSem = DispatchSemaphore(value: 0)
    private let tapDone = DispatchSemaphore(value: 0)
    private let tickDone = DispatchSemaphore(value: 0)
    private var tapThread: Thread?
    private var tickerThread: Thread?
    private var tap: CFMachPort?
    private var runLoop: CFRunLoop?
    private var readySem: DispatchSemaphore?

    public init(onStep: @escaping @Sendable (Step) -> Void,
                onTimeout: (@Sendable () -> Void)? = nil,
                maxSeconds: Double = 600.0,
                probes: Probes) {
        self.onStep = onStep
        self.onTimeout = onTimeout
        self.maxSeconds = maxSeconds > 0 ? maxSeconds : 600.0   // float(max_seconds or 600.0)
        self.probes = probes
        self.t0 = probes.now()
    }

    // ══════════════════════════════════════════════════════════
    // MARK: 归并层（⛔ 质量核心；raw 事件 → 宏 step；tap 回调与测试共用）
    // ══════════════════════════════════════════════════════════

    /// _ingest（L481-497）：规范化事件入口。⛔ 绝不抛异常——录制是旁路
    /// （Swift 探针闭包全部非 throwing，类型层保证）。
    public func ingest(_ raw: RawEvent) {
        let ts = raw.ts != 0 ? raw.ts : probes.now()   // float(raw.get("ts") or self._now())
        let (name, bid, pid) = probes.front()
        lock.lock()
        defer { lock.unlock() }
        if Self.isSelf(name: name, bid: bid, pid: pid) {
            // ⛔ 本应用前台时事件不录；切回自己窗口 = 焦点切换，截断打字聚合
            flushTextLocked()
            return
        }
        switch raw.kind {
        case .key:
            ingestKeyLocked(raw, ts: ts, app: name)
        case .mouseDown, .mouseUp:
            ingestMouseLocked(raw, ts: ts, app: name)
        }
    }

    /// _is_self（L499-505 + 适配③：双前缀）。
    public static func isSelf(name: String, bid: String, pid: Int32) -> Bool {
        if pid != 0 && pid == ProcessInfo.processInfo.processIdentifier { return true }
        let lowerBid = bid.lowercased()
        if selfBidPrefixes.contains(where: { lowerBid.hasPrefix($0) }) { return true }
        return selfNames.contains(name.trimmingCharacters(in: .whitespaces).lowercased())
    }

    private func ingestKeyLocked(_ raw: RawEvent, ts: Double, app: String) {
        let keycode = raw.keycode
        let flags = raw.flags
        let text = raw.text
        if Self.modifierKeycodes.contains(keycode) {
            return                             // 纯修饰键 down 不记（组合键以主键为准）
        }
        let cmd = (flags & Self.flagCmd) != 0
        let shift = (flags & Self.flagShift) != 0
        let opt = (flags & Self.flagOpt) != 0
        let ctrl = (flags & Self.flagCtrl) != 0

        // ⛔ 安全输入段按键整段不记（连长度都不记；不落 note 步——丢弃本身即是防护语义）
        if probes.secure() == true || probes.focusedSecure() {
            secureDropped += 1
            flushTextLocked()                  // 进入密码段前的明文先落（它不属于密码）
            return
        }

        if cmd || ctrl {
            // 修饰键 + 主键 → hotkey step（回放走 executor.keyboard_hotkey）
            flushTextLocked()
            guard let main = Self.mainKeyName(keycode) else {
                return                         // 主键无法映射：录了回放必失败，跳过
            }
            var mods: [String] = []
            if cmd { mods.append("cmd") }
            if shift { mods.append("shift") }
            if opt { mods.append("option") }
            if ctrl { mods.append("ctrl") }
            emit(Step(action: "key", x: nil, y: nil, app: app, element: nil,
                      payload: ["keys": .string((mods + [main]).joined(separator: "+"))]))
            return
        }

        if opt && text.isEmpty, Self.charMap[keycode] != nil {
            // option+键产出特殊字符（π、œ…），无 IME text 时 ANSI 表查不出 → 跳过
            // （录错字符比漏录更糟；option+方向键等走下方特殊键路径）
            return
        }
        let ch = !text.isEmpty ? text : Self.charFor(keycode, shift: shift)
        if let ch {
            if !pendingText.isEmpty && pendingApp != app {
                // ⛔ 切换焦点截断：不同 app 的击键绝不聚进同一段 type
                flushTextLocked()
            }
            pendingText.append(ch)
            pendingApp = app
            return
        }

        guard let name2 = Self.specialKeys[keycode] else {
            return                             // 不认识的键（如 117 前进删除）跳过
        }
        // ⛔ 退格/回车等特殊键必须截断打字聚合
        flushTextLocked()
        var mods: [String] = []
        if shift { mods.append("shift") }
        if opt { mods.append("option") }
        emit(Step(action: "key", x: nil, y: nil, app: app, element: nil,
                  payload: ["keys": .string(mods.isEmpty ? name2
                                            : (mods + [name2]).joined(separator: "+"))]))
    }

    private func ingestMouseLocked(_ raw: RawEvent, ts: Double, app: String) {
        let x = raw.x, y = raw.y
        let button = raw.button.isEmpty ? "left" : raw.button   // str(raw.get("button") or "left")
        if raw.kind == .mouseDown {
            flushTextLocked()                  // 点击 = 焦点可能切换，截断打字聚合
            checkClickExpiredLocked(ts)
            let hit = probes.hit(x, y)         // 元素语义富化；失败只记坐标（回放回落像素）
            let d = ClickInfo(x: x, y: y, ts: ts, hit: hit, app: app, button: button)
            down[button] = d
            if button == "left", let pend = pendingClick,
               ts - pend.ts <= Self.doubleClickMaxGap,
               abs(x - pend.x) <= Self.doubleClickMaxDist,
               abs(y - pend.y) <= Self.doubleClickMaxDist {
                dblArmed = true                // 第二次 down 落入双击窗口，暂缓定案
            } else {
                flushClickLocked()             // 上一次点击定案为单击
                dblArmed = false
            }
            return
        }
        // mouse_up
        guard let d = down.removeValue(forKey: button) else { return }
        let moved2 = (x - d.x) * (x - d.x) + (y - d.y) * (y - d.y)
        if moved2 > Self.dragMinDist * Self.dragMinDist {
            // 拖拽取舍（拍板）：记为【起点单击】+ payload.drag_to 落盘佐证。
            // 不记轨迹——多数「拖拽」场景（拖窗口/拖选）在宏语义下等价于起点的一次定位点击。
            flushClickLocked()
            dblArmed = false
            emitClickLocked(d, clicks: 1, dragTo: (x, y))
            return
        }
        if button == "left", dblArmed, let first = pendingClick {
            // ⛔ 同点双击必须合并为 double_click（而不是两个 click）
            pendingClick = nil
            dblArmed = false
            emitClickLocked(first, clicks: 2)
            return
        }
        flushClickLocked()
        pendingClick = d                       // 暂缓定案：等双击窗口/ticker/stop
    }

    private func emitClickLocked(_ d: ClickInfo, clicks: Int,
                                 dragTo: (Double, Double)? = nil) {
        var el: Element?
        if let hit = d.hit {
            var frame: [Double]?
            if let fr = hit.frame { frame = [fr.0, fr.1, fr.2, fr.3] }
            el = Element(role: String((hit.role ?? "").prefix(Self.roleMax)),
                         title: String((hit.title ?? "").prefix(Self.titleMax)),
                         frame: frame)
        }
        let app = !(d.hit?.app.isEmpty ?? true) ? (d.hit?.app ?? "") : d.app
        let button = d.button.isEmpty ? "left" : d.button
        let action: String
        if button == "left" {
            action = clicks <= 1 ? "click" : "double_click"
        } else if button == "right" {
            action = "right_click"
        } else {
            action = "click"                   // 中键等：按 click 记，payload 如实写 button
        }
        var payload: [String: JSONValue] = ["button": .string(button),
                                            "clicks": .int(Int64(clicks))]
        if let dragTo {
            payload["drag_to"] = .array([.double(Self.pyRound1(dragTo.0)),
                                         .double(Self.pyRound1(dragTo.1))])
        }
        emit(Step(action: action, x: Self.pyRound1(d.x), y: Self.pyRound1(d.y),
                  app: app, element: el, payload: payload))
    }

    private func checkClickExpiredLocked(_ now: Double) {
        if let pend = pendingClick, now - pend.ts > Self.doubleClickMaxGap {
            flushClickLocked()                 // 双击窗口已过，定案为单击
            dblArmed = false
        }
    }

    private func flushTextLocked() {
        guard !pendingText.isEmpty else { return }
        let s = pendingText.joined()
        pendingText = []
        emit(Step(action: "type", x: nil, y: nil, app: pendingApp, element: nil,
                  payload: ["text": .string(s)]))
    }

    private func flushClickLocked() {
        guard let d = pendingClick else { return }
        pendingClick = nil
        emitClickLocked(d, clicks: 1)
    }

    private func flushAllLocked() {
        flushTextLocked()
        flushClickLocked()
        dblArmed = false
        down.removeAll()
    }

    private func emit(_ step: Step) {
        // ⛔ 绝不抛异常（onStep 是录制旁路，搞挂 tap 回调是事故）——非 throwing 类型保证
        onStep(step)
    }

    /// Python round(x, 1)：对二进制真值做十进制一位、四舍六入五成双
    /// （CPython 正确舍入算法与 printf %.1f 同源；x*10 再半进偶会在
    /// 0.45→0.5 这类二进制边界上失真——0.45 真值 0.45000…0111 应入 0.5）。
    static func pyRound1(_ x: Double) -> Double {
        Double(String(format: "%.1f", x)) ?? x
    }

    // ══════════════════════════════════════════════════════════
    // MARK: ticker（_tick L666-678：双击超时定案 + 硬上限自动停）
    // ══════════════════════════════════════════════════════════

    /// _tick：单击双击窗口定案；硬上限到点触发 onTimeout 一次（视作正常 stop，有步落盘）。
    public func tick(_ now: Double) {
        var due = false
        lock.lock()
        checkClickExpiredLocked(now)
        if !timeoutFired, (now - t0) >= maxSeconds {
            // ⛔ 硬上限到点必须自动停
            timeoutFired = true
            due = true
        }
        lock.unlock()
        if due { onTimeout?() }                // 锁外回调（Python 同款）
    }

    private func tickLoop() {
        while true {
            if stopSem.wait(timeout: .now() + Self.tickInterval) != .timedOut { break }
            tick(probes.now())
        }
        tickDone.signal()
    }

    // ══════════════════════════════════════════════════════════
    // MARK: 生命周期（start/_run/_on_tap/stop L688-849；独立线程 CFRunLoop + 干净拆除）
    // ══════════════════════════════════════════════════════════

    /// start：创建 listen-only tap 并起跑。失败 → false + startError（可读原因）。
    public func start() -> Bool {
        let ready = DispatchSemaphore(value: 0)
        readySem = ready
        t0 = probes.now()
        let th = Thread { [weak self] in self?.run() }
        th.name = "cu-user-record-tap"
        tapThread = th
        th.start()
        if ready.wait(timeout: .now() + Self.tapStartTimeout) == .timedOut {
            startError = "tap_start_timeout: tap 线程 3s 未就绪"
            return false
        }
        if !startError.isEmpty { return false }
        let tk = Thread { [weak self] in self?.tickLoop() }
        tk.name = "cu-user-record-tick"
        tickerThread = tk
        tk.start()
        return true
    }

    /// _run：tap 线程体——建 tap → 挂 runloop source → CFRunLoopRun（stop 后返回）。
    private func run() {
        let mask: CGEventMask =
            (1 << Self.cgEventLeftDown) | (1 << Self.cgEventLeftUp)
            | (1 << Self.cgEventRightDown) | (1 << Self.cgEventRightUp)
            | (1 << Self.cgEventOtherDown) | (1 << Self.cgEventOtherUp)
            | (1 << Self.cgEventKeyDown)
        let created = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo -> Unmanaged<CGEvent>? in
                // ⛔ 绝不抛异常（抛进 CFRunLoop 是未定义行为）；listen-only 返回值被系统忽略
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let rec = Unmanaged<NativeUserRecorder>.fromOpaque(userInfo).takeUnretainedValue()
                rec.onTap(type: type, event: event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let created else {
            startError = "tap_create_failed: CGEventTapCreate 返回空——「输入监控」未授权时"
                + "系统直接拒绝建 tap（请检查 系统设置→隐私与安全性→输入监控）"
            readySem?.signal()                   // finally: ready.set()（防 start 干等）
            tapDone.signal()
            return
        }
        tap = created
        let rl = CFRunLoopGetCurrent()
        runLoop = rl
        if let src = CFMachPortCreateRunLoopSource(nil, created, 0) {
            CFRunLoopAddSource(rl, src, .commonModes)
        }
        CGEvent.tapEnable(tap: created, enable: true)
        readySem?.signal()
        CFRunLoopRun()
        // 干净拆除（CFRunLoopRun 已返回后）：source/tap 失效化
        CFMachPortInvalidate(created)
        tap = nil
        runLoop = nil
        tapDone.signal()
    }

    /// _on_tap：CGEventTap 回调——只做 CGEvent → raw → ingest。
    private func onTap(type: CGEventType, event: CGEvent) {
        let t = Int(type.rawValue)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // tap 被系统禁用（超时/用户输入风暴）→ 重建（重新启用即可）
            tapReenabled += 1
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        let ts = probes.now()
        if t == Self.cgEventKeyDown {
            let keycode = Int(event.getIntegerValueField(.keyboardEventKeycode))
            let flags = UInt64(event.flags.rawValue)
            var text = ""
            var buf = [UniChar](repeating: 0, count: 16)
            var actual = 0
            event.keyboardGetUnicodeString(maxStringLength: 16, actualStringLength: &actual,
                                           unicodeString: &buf)
            if actual > 0 {
                text = String(utf16CodeUnits: buf, count: min(actual, 16))
            }
            ingest(RawEvent(kind: .key, ts: ts, keycode: keycode, flags: flags, text: text))
        } else if t == Self.cgEventLeftDown || t == Self.cgEventLeftUp
                    || t == Self.cgEventRightDown || t == Self.cgEventRightUp
                    || t == Self.cgEventOtherDown || t == Self.cgEventOtherUp {
            let pt = event.location
            let btnNum = Int(event.getIntegerValueField(.mouseEventButtonNumber))
            let button = btnNum == 0 ? "left" : (btnNum == 1 ? "right" : "other")
            let isDown = t == Self.cgEventLeftDown || t == Self.cgEventRightDown
                || t == Self.cgEventOtherDown
            ingest(RawEvent(kind: isDown ? .mouseDown : .mouseUp, ts: ts,
                            x: Double(pt.x), y: Double(pt.y), button: button))
        }
    }

    /// stop（L804-849）：干净拆除——tap 停用 → runloop 停止 → join 兜底 →
    /// flush 残余聚合（幂等；⛔ 收尾步骤经 onStep 落出，调用方须保证录制单例仍在）。
    public func stop() {
        lifeLock.lock()
        if stopped {
            lifeLock.unlock()
            return
        }
        stopped = true
        lifeLock.unlock()
        stopSem.signal()                         // ticker 退出
        let cur = Thread.current
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let runLoop {                         // CFRunLoopStop 可跨线程调用
            CFRunLoopStop(runLoop)
            CFRunLoopWakeUp(runLoop)
        }
        if let tapThread, tapThread != cur {
            _ = tapDone.wait(timeout: .now() + Self.joinTimeout)
        }
        if let tickerThread, tickerThread != cur {
            _ = tickDone.wait(timeout: .now() + Self.joinTimeout)
        }
        lock.lock()
        flushAllLocked()                         // 收尾：打字段/待定案点击全部落宏
        lock.unlock()
        Self.activeLock.lock()
        if Self.active === self { Self.active = nil }
        Self.activeLock.unlock()
    }

    // ══════════════════════════════════════════════════════════
    // MARK: 模块级单例（L852-887：cu_macro 双保险之外的第二道单例闸 + 进程退出清理）
    // ══════════════════════════════════════════════════════════

    private static let activeLock = NSLock()
    private static var active: NativeUserRecorder?
    private static var atexitRegistered = false

    /// start_capture：创建并起跑系统级捕获。已在捕获 → nil（双保险；cu_macro 单例
    /// 已先挡）。tap 创建失败 → nil（排障入口是 listenAccessGranted + permission 端点）。
    public static func startCapture(onStep: @escaping @Sendable (Step) -> Void,
                                    onTimeout: (@Sendable () -> Void)? = nil,
                                    maxSeconds: Double = 600.0,
                                    probes: Probes) -> NativeUserRecorder? {
        activeLock.lock()
        defer { activeLock.unlock() }            // Python：整函数持 _ACTIVE_LOCK（含 start）
        if active != nil { return nil }
        let rec = NativeUserRecorder(onStep: onStep, onTimeout: onTimeout,
                                     maxSeconds: maxSeconds, probes: probes)
        guard rec.start() else { return nil }
        active = rec
        if !atexitRegistered {
            atexitRegistered = true
            atexit { NativeUserRecorder.cleanupAtExit() }
        }
        return rec
    }

    /// _cleanup_at_exit：进程退出钩子——录制中进程被杀也要干净拆 tap（防残留监听）。
    private static func cleanupAtExit() {
        activeLock.lock()
        let rec = active
        activeLock.unlock()
        rec?.stop()
    }
}
