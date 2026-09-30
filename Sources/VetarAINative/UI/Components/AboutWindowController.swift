//
//  AboutWindowController.swift
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

//  0.7.6 实测修复批续（业主 2026-09-27 22:03 反馈：标准关于面板格式错误、
//  字体错误，要求对齐旧版）——弃用 macOS 标准关于面板
//  （orderFrontStandardAboutPanel：Version X (Y) 英文格式 + credits 单一
//  小字，无字体层次），改自定义窗口，规格逐字考据自 Electron 线
//  subagent/main.js openAboutWindow()（0.4.34 业主截图实证形态）：
//    窗口 380×460 不可调、标题「关于 VetarAI」、白底；
//    图标 96×96 圆角 14 + 1px 描边 #1a1a1e、下间距 20；
//    名称 28px/700/#1a1a1e；
//    版本行「版本号：X.Y.Z」13px Menlo/#8e8e99、上间距 8；
//    中文介绍 14px/500/#5c5c66、上间距 12；
//    英文介绍 12px/#8e8e99、上间距 4。
//  有意偏差：底部新增版权行（12px/#8e8e99、上间距 12）——0.7.1 实测修复批
//  业主拍板「最下方的可以保留，是新增的部分我认可」。
//

import AppKit
import SwiftUI

/// 关于窗内容视图（独立出来便于测试与复用；布局数值=Electron 规格 1px:1pt）
struct AboutPanelView: View {
    var body: some View {
        VStack(spacing: 0) {
            Group {
                if let icon = NSApplication.shared.applicationIconImage {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                }
            }
            .frame(width: 96, height: 96)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(AboutPalette.ink, lineWidth: 1)
            )
            .padding(.bottom, 20)
            .accessibilityIdentifier("about.icon")

            Text(AppVersion.appName)
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(AboutPalette.ink)
                .accessibilityIdentifier("about.name")

            // Electron 原版整行 font-family:Menlo——中文自动回退 PingFang、
            // 数字走等宽（业主截图「0.4.34」点状零即 Menlo 特征）
            Text("版本号：\(AppVersion.current)")
                .font(.custom("Menlo", size: 13))
                .foregroundStyle(AboutPalette.mist)
                .padding(.top, 8)
                .accessibilityIdentifier("about.version")

            Text(AppVersion.taglineCN)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(AboutPalette.slate)
                .padding(.top, 12)
                .accessibilityIdentifier("about.tagline.cn")

            Text(AppVersion.taglineEN)
                .font(.system(size: 12))
                .foregroundStyle(AboutPalette.mist)
                .padding(.top, 4)
                .accessibilityIdentifier("about.tagline.en")

            Text(AppVersion.copyright)
                .font(.system(size: 12))
                .foregroundStyle(AboutPalette.mist)
                .padding(.top, 12)
                .accessibilityIdentifier("about.copyright")
        }
        .frame(width: AboutWindowController.contentWidth,
               height: AboutWindowController.contentHeight)
        .background(Color.white)  // Electron 原版恒白底（body background:#fff）
    }
}

/// Electron 原版色板（main.js openAboutWindow style 块逐字值）
enum AboutPalette {
    static let ink   = Color(red: 0x1a / 255, green: 0x1a / 255, blue: 0x1e / 255)  // #1a1a1e
    static let slate = Color(red: 0x5c / 255, green: 0x5c / 255, blue: 0x66 / 255)  // #5c5c66
    static let mist  = Color(red: 0x8e / 255, green: 0x8e / 255, blue: 0x99 / 255)  // #8e8e99
}

/// 单例窗口控制器：已存在则聚焦，关闭后释放（同 Electron aboutWindow 生命周期）
@MainActor
final class AboutWindowController {
    static let shared = AboutWindowController()

    /// 窗口规格（Electron：width:380, height:460, resizable/minimizable/maximizable:false）
    static let contentWidth: CGFloat = 380
    static let contentHeight: CGFloat = 460

    private var window: NSWindow?

    func makeWindow() -> NSWindow {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Self.contentWidth, height: Self.contentHeight),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win.title = "关于 \(AppVersion.appName)"
        win.contentViewController = NSHostingController(rootView: AboutPanelView())
        // 显式钉内容尺寸：指派 contentViewController 后宿主视图可能把内容
        // 区冲成 0×0（headless/首帧布局前），必须后置 setContentSize
        win.setContentSize(NSSize(width: Self.contentWidth, height: Self.contentHeight))
        win.isReleasedWhenClosed = false
        win.center()
        return win
    }

    func show() {
        if let window, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let win = makeWindow()
        window = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
