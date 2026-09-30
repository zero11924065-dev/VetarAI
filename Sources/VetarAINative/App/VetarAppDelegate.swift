//
//  VetarAppDelegate.swift
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

//  ── W11 根因结论（业主实测：关闭后 Dock 黑点仍在 / 点图标无法重开 / 须右键退出）──
//  ① 0.4.x Electron 线实际行为（subagent/main.js:526，亲查）：
//       app.on('window-all-closed', () => { stopSidecar(); app.quit(); });
//     ——未写 Electron 模板常见的 `if (process.platform !== "darwin")` 留驻例外，
//     即 0.4.x 在 macOS 上也是「关末窗即退应用」；用户多年肌肉记忆 = 关窗即退。
//  ② 原生线（0.5.0~0.7.4）现状：纯 SwiftUI @main App、无 NSApplicationDelegate——
//     applicationShouldTerminateAfterLastWindowClosed 缺省 false → 关末窗进程
//     留驻（Dock 黑点不消失，与 0.4.x 行为相反，用户误判「进程没退干净」）；
//     applicationShouldHandleReopen 未实现 → 点 Dock 图标无反应，只能右键退出。
//  ③ 终止链排查结论：AppState / NativeRuntime 无 applicationWillTerminate 拦截、
//     无同步 flush 挂起点（NativeLlamaCppDriver / NativeUserRecorder 的 atexit
//     仅做子进程/事件 tap 清理，非阻塞；右键退出能成功也佐证进程未挂起）——
//     不是「终止链挂起」，是缺末窗关闭策略的单纯行为缺口。
//  产品决策（对齐 0.4.x）：关最后一个窗口 = 退出应用。
//  不留驻，故 applicationShouldHandleReopen 无需实现（SwiftUI 缺省重开覆盖
//  残余留驻场景：如关于面板开着时关主窗应用不退，点图标走系统默认重开）。
//
//  ── W9（Cmd+Q 忙守边界）──
//  0.7.4 W8 的 windowShouldClose 闸只覆盖关窗按钮 / Cmd+W；Cmd+Q、菜单退出、
//  NSApp.terminate 均不经 windowShouldClose，必须经 NSApplicationDelegate。
//  此处接同一忙守闸（BusyGuardAlert.gate，.quit 场景文案如实分叉，见
//  PanelBusyGuard.swift）——确认放行 .terminateNow，取消 .terminateCancel。
//
//  双弹窗防线：关末窗路径 windowShouldClose 闸已取过用户同意，随后系统在同一条
//  同步链上触发 applicationShouldTerminate——用 skipQuitGateOnce 一次性标记直通，
//  避免同一动作弹两次确认（标记只在 afterLastWindowClosed → shouldTerminate
//  紧邻同步链内置位并消费；其余路径不会置位）。
//

import AppKit

final class VetarAppDelegate: NSObject, NSApplicationDelegate {

    /// 忙守闸（VetarAINativeApp 首帧布线；未布线前忙守不生效、终止直通）
    var busyGuard: PanelBusyGuard?

    /// W11 一次性直通标记：末窗关闭链（windowShouldClose 闸已取同意）免二次弹窗
    private var skipQuitGateOnce = false

    /// W11 核心修复：关最后一个窗口即终止应用（对齐 0.4.x window-all-closed → app.quit()）
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        skipQuitGateOnce = true
        return true
    }

    /// W9：Cmd+Q / 菜单退出 / NSApp.terminate 统一忙守闸。
    /// 主线程同步答复场景（与 windowShouldClose 同型），NSAlert.runModal 可用。
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let skip = skipQuitGateOnce
        skipQuitGateOnce = false
        guard let guard_ = busyGuard else { return .terminateNow }
        // NSApplicationDelegate 回调恒主线程；忙守状态机为 @MainActor——
        // 与 WindowCloseGuard 同款 MainActor.assumeIsolated 桥接。
        let needsConfirm = MainActor.assumeIsolated {
            QuitGatePolicy.needsConfirmation(skipAfterWindowClose: skip,
                                             isBusy: guard_.isBusy)
        }
        guard needsConfirm else { return .terminateNow }
        let pass = MainActor.assumeIsolated {
            BusyGuardAlert.gate(guard_, context: .quit)
        }
        return pass ? .terminateNow : .terminateCancel
    }
}
