//
//  VToast.swift
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

//  Toast 轻提示：顶部居中浮条，3s 自动消失（对齐 bgToast 深色胶囊观感）。
//  用法：ToastCenter.shared.show("已保存")；RootView 已挂 overlay。
//

import SwiftUI

public struct VToast: Equatable {
    public enum Kind { case info, success, error }
    public let id = UUID()
    public let kind: Kind
    public let text: String
    public static func == (l: VToast, r: VToast) -> Bool { l.id == r.id }
}

@MainActor
public final class ToastCenter: ObservableObject {
    public static let shared = ToastCenter()

    @Published public private(set) var current: VToast?
    private var dismissTask: Task<Void, Never>?

    public func show(_ text: String, kind: VToast.Kind = .info, duration: TimeInterval = 3) {
        dismissTask?.cancel()
        current = VToast(kind: kind, text: text)
        dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.current = nil
        }
    }
}

public struct ToastHostView: View {
    @ObservedObject var center: ToastCenter

    @MainActor public init(center: ToastCenter = .shared) { self.center = center }

    public var body: some View {
        VStack {
            if let toast = center.current {
                HStack(spacing: 6) {
                    if toast.kind == .success {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(VTheme.ok)
                    } else if toast.kind == .error {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(VTheme.danger)
                    }
                    Text(toast.text).font(VTheme.Typo.caption)
                }
                .foregroundStyle(Color.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(VTheme.toastBg, in: Capsule())   // 方向2 波次4b：手写 0x1C1C1A 0.92 收编 toastBg 令牌（原版 :56；ink 令牌深色翻白不可用，见 VTheme）
                // 方向2 波次4b：浮层轻提示阴影收编 Shadow.popover（原版 :57 手写 0.15/8/3）
                .shadow(color: VTheme.Shadow.popover.color, radius: VTheme.Shadow.popover.radius,
                        y: VTheme.Shadow.popover.y)
                .padding(.top, 12)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
            Spacer()
        }
        .animation(VTheme.Motion.panel, value: center.current)   // 方向2 波次4b：手写 easeInOut(0.2) 同值换令牌引用（原版 :63）
        .allowsHitTesting(false)
    }
}
