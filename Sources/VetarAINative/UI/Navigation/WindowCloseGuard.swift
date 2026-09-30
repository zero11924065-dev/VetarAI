//
//  WindowCloseGuard.swift
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

//  工作流在跑 / 圆桌讨论进行中时，点窗口关闭按钮 / Cmd+W 先弹 NSAlert 确认
// （防误关，业主定性核心功能保护）。
//
//  实现：NSWindowDelegate 代理——windowShouldClose 同步答复走确认闸；
//  其余消息经 forwardingTarget 转发原 delegate（SwiftUI 若挂过自己的 delegate
//  不丢行为）。代理对象经关联引用挂窗上保活（NSWindow.delegate 是弱引用）。
//
//  Cmd+Q 边界（0.7.5 W9 已补齐）：Cmd+Q/菜单退出不经 windowShouldClose，
//  由 VetarAppDelegate.applicationShouldTerminate 接同一忙守闸（.quit 场景）。
//  W11 末窗关闭即退出应用后，本闸同时是「关窗=退出」的确认点（应用侧经
//  skipQuitGateOnce 一次性标记防双弹窗，见 VetarAppDelegate 头注）。
//

import SwiftUI
import AppKit
import ObjectiveC

struct WindowCloseGuard: NSViewRepresentable {

    private let busyGuard: PanelBusyGuard

    init(busyGuard: PanelBusyGuard) { self.busyGuard = busyGuard }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { install(on: view) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { install(on: nsView) }
    }

    /// 关联对象键（代理挂窗保活）
    private static var assocKey: UInt8 = 0

    private func install(on view: NSView) {
        guard let window = view.window else { return }
        // 幂等：已装过不重复装（updateNSView 会反复来）
        if objc_getAssociatedObject(window, &Self.assocKey) != nil { return }
        let proxy = WindowCloseGuardDelegate(original: window.delegate) { [busyGuard] in
            // windowShouldClose 恒主线程调用
            MainActor.assumeIsolated {
                BusyGuardAlert.gate(busyGuard, context: .closeWindow)
            }
        }
        objc_setAssociatedObject(window, &Self.assocKey, proxy, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        window.delegate = proxy
    }
}

/// NSWindowDelegate 代理：windowShouldClose 走 busy 确认闸，其余转发原 delegate。
final class WindowCloseGuardDelegate: NSObject, NSWindowDelegate {

    private weak var original: NSWindowDelegate?
    private let shouldClose: () -> Bool

    init(original: NSWindowDelegate?, shouldClose: @escaping () -> Bool) {
        self.original = original
        self.shouldClose = shouldClose
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { shouldClose() }

    override func responds(to aSelector: Selector!) -> Bool {
        if aSelector == #selector(NSWindowDelegate.windowShouldClose(_:)) { return true }
        return original?.responds(to: aSelector) ?? super.responds(to: aSelector)
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        if let original, original.responds(to: aSelector) { return original }
        return super.forwardingTarget(for: aSelector)
    }
}
