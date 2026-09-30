//
//  NativeCUPlatformReal.swift
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

//  真 CG/AX 平台适配层：NativeCUPlatformAdapter 的生产实现。
//  移植自 sidecar/computer_use/executor.py + ax_element.py 的 ctypes 直调层：
//    · executor.py 的 CGEventCreateMouseEvent / CGEventCreateKeyboardEvent /
//      CGEventKeyboardSetUnicodeString / CGEventSetIntegerValueField 调用序列；
//    · ax_element.py 的 AXUIElementCreateSystemWide + AXUIElementCopyElementAtPosition
//      命中测试、_describe(AXRole/AXTitle/AXPosition/AXSize)、app_elements 局部枚举
//      （窗口 ≤8、节点 ≤300、深度 ≤2 硬上限，⛔ 禁止全树遍历）。
//
//  偏差（已决策，写进 W4c 汇报）：
//    · 截屏：Python 走 `screencapture` 子进程落盘再读回；原生改
//      CGWindowListCreateImage 内存直出 → CGContext 降采样 → CGImageDestination
//      JPEG。少一次磁盘往返，口径等价（全屏 + 长边降采样 + JPEG 质量参数）。
//    · 前台应用名：Python 走 osascript JXA；原生改 NSWorkspace.frontmostApplication。
//    · pid → 进程名：Python 走 `ps -p pid -o comm=`；原生改 NSRunningApplication。
//    · pgrep -x/-ix/-i 三段回退 → NSWorkspace.runningApplications 名字三段匹配
//      （AX 枚举只关心 GUI 进程，语义等价）。
//
//  ⛔ 本文件只做编译链接验证；单元测试一律用假 adapter（真层会动真鼠标键盘/截屏）。
//

import Foundation
import AppKit
import ApplicationServices
import ImageIO
import UniformTypeIdentifiers

public final class NativeCoreGraphicsCUAdapter: NativeCUPlatformAdapter, @unchecked Sendable {

    // ── ax_element.py APP_ENUM_* 硬上限（逐字）──
    public static let enumMaxWindows = 8
    public static let enumMaxNodes = 300
    public static let enumMaxDepth = 2

    private let errLock = NSLock()
    private var lastError = ""

    public init() {}

    private func setErr(_ s: String) {
        errLock.lock(); lastError = s; errLock.unlock()
    }

    /// 模块级 LAST_ERROR 同构：最近一次 hitTest/appElements 的可读失败原因。
    public func axLastError() -> String {
        errLock.lock(); defer { errLock.unlock() }
        return lastError
    }

    // ══════════════════════════════════════════════════════════
    // MARK: 权限状态位（只读，不触发弹窗）
    // ══════════════════════════════════════════════════════════

    public func axTrusted() -> Bool? {
        AXIsProcessTrusted()
    }

    public func screenCaptureAccess() -> Bool? {
        CGPreflightScreenCaptureAccess()
    }

    // ══════════════════════════════════════════════════════════
    // MARK: 屏幕几何 + 截屏
    // ══════════════════════════════════════════════════════════

    /// executor.py _screen_geometry：CGDisplayPixelsWide/High 实测返回【逻辑点】
    /// （缩放模式下 1728x1117 而非物理像素），引擎坐标越界检查直接用。
    public func screenGeometry() -> (Int, Int) {
        let did = CGMainDisplayID()
        return (Int(CGDisplayPixelsWide(did)), Int(CGDisplayPixelsHigh(did)))
    }

    /// 截全屏 → 长边降采样 → JPEG 内存直出（替代 screencapture 子进程）。
    public func captureScreenshot(maxLongEdge: Int, jpegQuality: Int) throws -> NativeCUScreenshot {
        guard let img = CGWindowListCreateImage(
                .infinite, .optionOnScreenOnly, kCGNullWindowID,
                [.boundsIgnoreFraming, .nominalResolution]) else {
            throw NativeCUPlatformError.captureFailed(
                "CGWindowListCreateImage 返回空（可能未授予屏幕录制权限）")
        }
        let w = img.width, h = img.height
        var sw = w, sh = h
        let longEdge = max(w, h)
        if maxLongEdge > 0, longEdge > maxLongEdge {
            let scale = Double(maxLongEdge) / Double(longEdge)
            sw = max(1, Int((Double(w) * scale).rounded()))
            sh = max(1, Int((Double(h) * scale).rounded()))
        }
        var out = img
        if sw != w || sh != h {
            guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
                  let ctx = CGContext(data: nil, width: sw, height: sh,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: cs,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else {
                throw NativeCUPlatformError.captureFailed("降采样上下文创建失败")
            }
            ctx.interpolationQuality = .high
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: sw, height: sh))
            guard let scaled = ctx.makeImage() else {
                throw NativeCUPlatformError.captureFailed("降采样失败")
            }
            out = scaled
        }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
                data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw NativeCUPlatformError.captureFailed("JPEG 编码器创建失败")
        }
        CGImageDestinationAddImage(dest, out, [
            kCGImageDestinationLossyCompressionQuality: Double(jpegQuality) / 100.0,
        ] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw NativeCUPlatformError.captureFailed("JPEG 编码失败")
        }
        return NativeCUScreenshot(jpegData: data as Data, widthPx: w, heightPx: h,
                                  sentWidth: sw, sentHeight: sh)
    }

    // ══════════════════════════════════════════════════════════
    // MARK: 鼠标事件（executor.py mouse_click 的事件构造序列）
    // ══════════════════════════════════════════════════════════

    public func postMouseMove(x: Double, y: Double) throws {
        guard let ev = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                               mouseCursorPosition: CGPoint(x: x, y: y),
                               mouseButton: .left) else {
            throw NativeCUPlatformError.eventCreateFailed
        }
        ev.post(tap: .cghidEventTap)
    }

    /// down/up 成对由引擎调用；clickState > 1 时写 kCGMouseEventClickState
    /// （executor.py L782-784：双击第二次 down/up 必须带 clickState，
    /// 否则系统当两次单击处理）。
    public func postMouseButton(down: Bool, button: String, x: Double, y: Double,
                                clickState: Int) throws {
        let btn: CGMouseButton = (button == "right") ? .right : .left
        let type: CGEventType
        switch (btn, down) {
        case (.left, true):  type = .leftMouseDown
        case (.left, false): type = .leftMouseUp
        case (.right, true): type = .rightMouseDown
        default:             type = .rightMouseUp
        }
        guard let ev = CGEvent(mouseEventSource: nil, mouseType: type,
                               mouseCursorPosition: CGPoint(x: x, y: y),
                               mouseButton: btn) else {
            throw NativeCUPlatformError.eventCreateFailed
        }
        if clickState > 1 {
            ev.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
        }
        ev.post(tap: .cghidEventTap)
    }

    // ══════════════════════════════════════════════════════════
    // MARK: 键盘事件（executor.py keyboard_type / keyboard_hotkey）
    // ══════════════════════════════════════════════════════════

    /// unicodeUnits 非空：CGEventKeyboardSetUnicodeString（type 分块输入，keyCode 恒 0）；
    /// 否则纯 keyCode 事件（hotkey）。flags ≠ 0 时 CGEventSetFlags。
    public func postKeyboard(keyCode: UInt16, down: Bool, flags: UInt64,
                             unicodeUnits: [UInt16]) throws {
        guard let ev = CGEvent(keyboardEventSource: nil, virtualKey: keyCode,
                               keyDown: down) else {
            throw NativeCUPlatformError.eventCreateFailed
        }
        if !unicodeUnits.isEmpty {
            // UniChar 缓冲：引擎已完成 UTF-16 代理对拆分与 32 单元分块
            unicodeUnits.withUnsafeBufferPointer { buf in
                ev.keyboardSetUnicodeString(stringLength: buf.count,
                                            unicodeString: buf.baseAddress)
            }
        }
        if flags != 0 {
            ev.flags = CGEventFlags(rawValue: flags)
        }
        ev.post(tap: .cghidEventTap)
    }

    // ══════════════════════════════════════════════════════════
    // MARK: AX 命中测试（ax_element.py hit_test + _describe）
    // ══════════════════════════════════════════════════════════

    /// _describe：读一个元素的 AXRole/AXTitle/AXPosition/AXSize。
    /// 每个属性独立失败容忍（读不到 → nil 字段），绝不向上抛。
    private func describe(_ el: AXUIElement) -> (role: String?, title: String?,
                                                 frame: (Double, Double, Double, Double)?) {
        var role: String? = nil
        var title: String? = nil
        var frame: (Double, Double, Double, Double)? = nil

        var rv: CFTypeRef?
        if AXUIElementCopyAttributeValue(el, "AXRole" as CFString, &rv) == .success,
           let r = rv as? String { role = r }
        var tv: CFTypeRef?
        if AXUIElementCopyAttributeValue(el, "AXTitle" as CFString, &tv) == .success,
           let t = tv as? String { title = t }

        var pv: CFTypeRef?
        var pos: CGPoint?
        if AXUIElementCopyAttributeValue(el, "AXPosition" as CFString, &pv) == .success,
           let p = pv {
            var pt = CGPoint.zero
            if AXValueGetValue(p as! AXValue, .cgPoint, &pt) { pos = pt }
        }
        var sv: CFTypeRef?
        var size: CGSize?
        if AXUIElementCopyAttributeValue(el, "AXSize" as CFString, &sv) == .success,
           let s = sv {
            var sz = CGSize.zero
            if AXValueGetValue(s as! AXValue, .cgSize, &sz) { size = sz }
        }
        if let pos, let size {
            frame = (Double(pos.x), Double(pos.y), Double(size.width), Double(size.height))
        }
        return (role, title, frame)
    }

    /// pid → 进程名（best-effort；替代 `ps -p pid -o comm=`）。
    private func appName(forPid pid: pid_t) -> String {
        NSRunningApplication(processIdentifier: pid)?.localizedName ?? ""
    }

    /// hit_test：逻辑点 (x,y) 处 AX 元素。无权限/无元素/任何 err → nil，
    /// 失败原因写 lastError（⛔ 校正链失败必须能静默回落像素坐标）。
    public func hitTest(x: Double, y: Double) -> NativeCUElementHit? {
        setErr("")
        guard x.isFinite, y.isFinite else {
            setErr("bad_arg: 坐标非法（\(x),\(y)）")
            return nil
        }
        guard AXIsProcessTrusted() else {
            setErr("accessibility_denied: 辅助功能未授权，AX 读树不可用")
            return nil
        }
        let sw = AXUIElementCreateSystemWide()
        var el: AXUIElement?
        let err = AXUIElementCopyElementAtPosition(sw, Float(x), Float(y), &el)
        guard err == .success, let el else {
            setErr("ax_error: AXUIElementCopyElementAtPosition → \(err.rawValue)")
            return nil
        }
        let d = describe(el)
        var pid: pid_t = 0
        AXUIElementGetPid(el, &pid)
        return NativeCUElementHit(role: d.role, title: d.title, frame: d.frame,
                                  app: appName(forPid: pid), pid: Int32(pid))
    }

    // ══════════════════════════════════════════════════════════
    // MARK: 局部枚举（ax_element.py app_elements；窗口+depth≤2 层）
    // ══════════════════════════════════════════════════════════

    /// pgrep -x / -ix / -i 三段回退的原生等价：运行中 GUI 应用按名字匹配。
    private func findPid(forApp name: String) -> pid_t? {
        let apps = NSWorkspace.shared.runningApplications
        let lowered = name.lowercased()
        if let exact = apps.first(where: { $0.localizedName == name }) {
            return exact.processIdentifier
        }
        if let ciExact = apps.first(where: { $0.localizedName?.lowercased() == lowered }) {
            return ciExact.processIdentifier
        }
        if let partial = apps.first(where: {
            $0.localizedName?.lowercased().contains(lowered) == true
        }) {
            return partial.processIdentifier
        }
        return nil
    }

    /// 读 AXChildren（任何 err → 空数组；预算由调用方控制）。
    private func children(of el: AXUIElement) -> [AXUIElement] {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, "AXChildren" as CFString, &v) == .success,
              let arr = v as? [AXUIElement] else { return [] }
        return arr
    }

    /// _enum_children：depth 层局部枚举，budget 倒数控制总量（⛔ 禁止全树遍历）。
    private func enumChildren(_ parent: AXUIElement, depth: Int, budget: inout Int,
                              app: String, pid: Int32, into out: inout [NativeCUElementHit]) {
        guard depth > 0, budget > 0 else { return }
        for child in children(of: parent) {
            guard budget > 0 else { return }
            budget -= 1
            let d = describe(child)
            out.append(NativeCUElementHit(role: d.role, title: d.title,
                                          frame: d.frame, app: app, pid: pid))
            if depth > 1, budget > 0 {
                enumChildren(child, depth: depth - 1, budget: &budget,
                             app: app, pid: pid, into: &out)
            }
        }
    }

    /// app_elements：目标 app 的窗口 + depth≤2 层局部枚举（命中测试兜底路径）。
    /// app 未运行/无窗口/任何 err → 空列表 + lastError（回放 R4 中止判定用）。
    public func appElements(app: String, depth: Int) -> [NativeCUElementHit] {
        setErr("")
        let name = app.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else {
            setErr("bad_arg: app 名为空")
            return []
        }
        guard AXIsProcessTrusted() else {
            setErr("accessibility_denied: 辅助功能未授权，AX 读树不可用")
            return []
        }
        guard let pid = findPid(forApp: name) else {
            setErr("app_not_running: 应用 \(name) 未在运行（或不是 GUI 进程）")
            return []
        }
        let d = max(0, min(depth, Self.enumMaxDepth))
        let appEl = AXUIElementCreateApplication(pid)
        var wv: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appEl, "AXWindows" as CFString, &wv) == .success,
              let windows = wv as? [AXUIElement], !windows.isEmpty else {
            setErr("no_windows: 应用 \(name) 没有可读窗口")
            return []
        }
        var out: [NativeCUElementHit] = []
        var budget = Self.enumMaxNodes
        for win in windows.prefix(Self.enumMaxWindows) {
            guard budget > 0 else { break }
            budget -= 1
            let wd = describe(win)
            out.append(NativeCUElementHit(role: wd.role, title: wd.title,
                                          frame: wd.frame, app: name, pid: Int32(pid)))
            if d > 0, budget > 0 {
                enumChildren(win, depth: d, budget: &budget,
                             app: name, pid: Int32(pid), into: &out)
            }
        }
        return out
    }

    // ══════════════════════════════════════════════════════════
    // MARK: 前台应用名
    // ══════════════════════════════════════════════════════════

    /// NSWorkspace.frontmostApplication（替代 osascript JXA；读不到 → 空串）。
    public func frontmostApp() -> String {
        NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
    }
}
