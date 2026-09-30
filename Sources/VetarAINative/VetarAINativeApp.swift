//
//  VetarAINativeApp.swift
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

//  应用入口：窗口标题/最小尺寸/位置记忆（WindowConfigurator），
//  全局 AppState 注入 + 关于窗口命令。
//
//  启动参数（P3-W6 侧车归零后口径）：
//  - `-sidecar.dataRoot <path>`：保留——数据根注入（NativeRuntime 读取，
//    键名与旧侧车时代完全一致，冒烟脚本零迁移）；
//  - `-sidecar.port` / `-sidecar.binaryPath`：已随侧车子进程管理器
//    （SidecarManager）一同退役删除，传入无效；
//  - `-nativeKernel.enabled`：恒原生架构下无意义，NativeRuntime 读到 NO
//    时记一行日志并忽略（容忍旧冒烟脚本残留）。
//

import SwiftUI

@main
struct VetarAINativeApp: App {
    // 0.7.5 W9/W11：应用级 NSApplicationDelegate——W11 末窗关闭即退（对齐 0.4.x
    // window-all-closed → app.quit()，根治 Dock 黑点残留/点图标无法重开）；
    // W9 Cmd+Q/菜单退出接忙守闸（不经 windowShouldClose 的边界补齐）。
    // 根因对照与决策全文见 VetarAppDelegate.swift 头注。
    @NSApplicationDelegateAdaptor(VetarAppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup("\(AppVersion.appName)") {
            RootView()
                .environmentObject(appState)
                // 忙守闸布线：delegate 先于 AppState 构造，首帧把 AppState 持有的
                // busyGuard 注入（未注入前终止直通，不影响启动期）。
                .onAppear { appDelegate.busyGuard = appState.busyGuard }
                // 0.5.2 W7：minWidth 960 → 800——960 地板高于折叠线 920 使
                // 侧栏折叠对拖拽不可达（用户实证：缩到最窄侧栏不收、右栏/顶栏
                // 被裁）。800 地板低于折叠线，留出 800~919 共 120pt 纯折叠区。
                // 有意偏差：0.4.x main.js:185 无地板，原生设 800 保内容区最低
                // 可用（rail 52 + 内容 748）。与 WindowConfigurator.minSize 同值。
                .frame(minWidth: 800, minHeight: 600)
        }
        .defaultSize(width: 1200, height: 760)
        .commands {
            CommandGroup(replacing: .appInfo) {
                // Bug 7（0.7.1 实测修复批，业主拍板方案 A）：恢复菜单栏「关于」入口
                // （显式自绘窗口——debug 裸二进制无 Info.plist 也能完整显示）。
                // 设置覆盖页「关于」导航项同步撤除，原 AboutPanel 诊断能力搬入
                // 基础设置底部「诊断」区（AX id 不变）。
                // 0.7.6 实测修复批续（业主 2026-09-27 22:03：标准关于面板格式/字体
                // 均错误）：弃用 macOS 标准关于面板，改 AboutWindowController
                // 自定义窗口，规格逐字考据 Electron 线 main.js openAboutWindow
                // （380×460/图标96圆角描边/版本行「版本号：X.Y.Z」Menlo 灰/
                // 中文介绍深色/英文介绍灰/版权行保留）。
                Button("关于 \(AppVersion.appName)") {
                    Task { @MainActor in AboutWindowController.shared.show() }
                }
            }
        }
    }
}
