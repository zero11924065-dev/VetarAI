//
//  WindowHelpers.swift
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

//  NSWindow 桥接：最小尺寸 + 窗口位置记忆（frameAutosaveName）。
//

import SwiftUI
import AppKit

/// 把 NSWindow 抓到 SwiftUI 层：设置最小尺寸与 frame autosave（窗口位置/尺寸记忆）。
public struct WindowConfigurator: NSViewRepresentable {
    public let minSize: NSSize
    public let autosaveName: String

    // 0.5.2 W7：默认 minSize 960 → 800，与 VetarAINativeApp .frame(minWidth:)
    // 同值（两处口径必须一致——NSWindow.minSize 才是真正钳制拖拽/AX 写尺寸的
    // 地板；960 高于折叠线 920 曾使侧栏折叠不可达）。
    public init(minSize: NSSize = NSSize(width: 800, height: 600),
                autosaveName: String = "VetarAINativeMainWindow") {
        self.minSize = minSize
        self.autosaveName = autosaveName
    }

    public func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { configure(view) }
        return view
    }

    public func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { configure(nsView) }
    }

    private func configure(_ view: NSView) {
        guard let window = view.window else { return }
        window.minSize = minSize
        if window.frameAutosaveName != autosaveName {
            window.setFrameAutosaveName(autosaveName)
        }
    }
}
