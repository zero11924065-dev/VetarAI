//
//  ZoomControl.swift
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

//  收编口径（两画布原各写一套）：
//    · 外观走 Studio 版语言：磨砂 .regularMaterial 底（高 36 圆角 10）+ 百分比显示；
//      Workflow 原 vSecondary 图标钮组 + bgCard.opacity(0.85) 底收编进本组件。
//    · 步进统一 0.2（Studio 原档位表 [0.25,0.4,…,2.0] 退役）；缩放域由调用方给：
//      Studio 0.25–2.0（StudioCanvasLayout.clampZoom 同口径）、Workflow 0.4–2.5，
//      组件支持全域 0.25–2.5。
//    · 三态齐全（hover 浮 bgHover / pressed 0.6 / disabled 0.45，VButtons 波次1 口径），
//      替代两画布原手写 .plain 无 hover 钮。
//    · AX：−/＋ 文本钮补「缩小/放大」label（Studio 原无）；百分比钮「复位缩放」label
//      + 当前百分比 value（Workflow 波次2 复位钮 label 语义保留）；键盘缩放
//      （Cmd+=/-/0）留在各画布本体，语义不动。
//    · AX id：叶子 id 由调用方给 idPrefix 拼出（<prefix>.out/.pct/.in/.fit），
//      Studio 原 studio.zoom.* 叶子 id 原样保留；容器不挂 id（DBG-160 纪律——
//      注意 studio.zoomControl 为已移除容器 id，禁复现）。
//

import SwiftUI

public struct ZoomControl: View {
    /// 当前缩放（组件步进直接改写；外部手势缩放经绑定回流，百分比即时反映）
    @Binding public var zoom: CGFloat
    /// 缩放域（Studio 0.25–2.0 / Workflow 0.4–2.5，均在组件全域 0.25–2.5 内）
    public let range: ClosedRange<CGFloat>
    /// 步进（统一 0.2）
    public var step: CGFloat
    /// 百分比钮点击（复位 100%；nil = 组件默认 zoom=1 + zoomSnap 动效）。
    /// Workflow 传 resetView（zoom/pan 双清零语义保留）；Studio 传视口中心锚定版。
    public var onResetZoom: (() -> Void)?
    /// 可选「适应」钮（Studio 自动适应视图；Workflow 无此钮传 nil）
    public var onFit: (() -> Void)?
    /// 缩放变化后置钩子（Studio 缩放指示胶囊节拍；变化由组件产生时调用）
    public var onZoomChange: () -> Void
    /// 叶子 AX id 前缀（拼 <prefix>.out/.pct/.in/.fit；nil = 不挂叶子 id）
    public var idPrefix: String?

    public init(zoom: Binding<CGFloat>,
                range: ClosedRange<CGFloat> = 0.25...2.5,
                step: CGFloat = 0.2,
                onResetZoom: (() -> Void)? = nil,
                onFit: (() -> Void)? = nil,
                onZoomChange: @escaping () -> Void = {},
                idPrefix: String? = nil) {
        self._zoom = zoom
        self.range = range
        self.step = step
        self.onResetZoom = onResetZoom
        self.onFit = onFit
        self.onZoomChange = onZoomChange
        self.idPrefix = idPrefix
    }

    public var body: some View {
        HStack(spacing: 2) {
            Button { stepZoom(by: -step) } label: {
                Text("−")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(ZoomControlButtonStyle())
            .accessibilityLabel("缩小")
            .accessibilityIdentifierPrefix(idPrefix, suffix: "out")
            Button {
                if let onResetZoom {
                    onResetZoom()
                    onZoomChange()
                } else {
                    withAnimation(VTheme.Motion.zoomSnap) { zoom = 1.0 }
                    onZoomChange()
                }
            } label: {
                Text("\(Int((zoom * 100).rounded()))%")
                    .font(.system(size: 11).monospacedDigit())
                    .frame(width: 44, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(ZoomControlButtonStyle())
            .accessibilityLabel("复位缩放")
            .accessibilityValue("\(Int((zoom * 100).rounded()))%")
            .accessibilityIdentifierPrefix(idPrefix, suffix: "pct")
            Button { stepZoom(by: step) } label: {
                Text("+")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(ZoomControlButtonStyle())
            .accessibilityLabel("放大")
            .accessibilityIdentifierPrefix(idPrefix, suffix: "in")
            if let onFit {
                Divider().frame(height: 16).padding(.horizontal, 3)
                Button {
                    onFit()
                    onZoomChange()
                } label: {
                    Text("适应")
                        .font(.system(size: 11))
                        .padding(.horizontal, 6)
                        .frame(height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(ZoomControlButtonStyle(foreground: VTheme.textSecondary))
                .accessibilityIdentifierPrefix(idPrefix, suffix: "fit")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 36)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        // DBG-160：容器不挂 id（叶子 id 由 idPrefix 拼在 −/%/+/适应 上）
    }

    /// 步进缩放：±step，钳入缩放域，松手吸附档动效（zoomSnap 100ms）
    private func stepZoom(by delta: CGFloat) {
        let new = min(range.upperBound, max(range.lowerBound, zoom + delta))
        guard new != zoom else { return }
        withAnimation(VTheme.Motion.zoomSnap) { zoom = new }
        onZoomChange()
    }
}

/// 缩放控件内部钮三态（hover 浮 bgHover 浅底 / pressed 0.6 / disabled 0.45——
/// VButtons 波次1 口径；磨砂底上的小命中目标，圆角 s 贴 capsule 组风格）。
private struct ZoomControlButtonStyle: ButtonStyle {
    var foreground: Color = VTheme.textPrimary
    @State private var isHovered = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(foreground)
            .background(isHovered && isEnabled ? VTheme.bgHover : Color.clear,
                        in: RoundedRectangle(cornerRadius: VTheme.Radius.s))
            .opacity(isEnabled ? (configuration.isPressed ? 0.6 : 1) : 0.45)
            .onHover { isHovered = $0 }
            .animation(VTheme.Motion.micro, value: isHovered)
    }
}

private extension View {
    /// idPrefix 非 nil 时挂 "<prefix>.<suffix>" 叶子 id（插值形式，字面量唯一性审计不扫；
    /// 全局唯一性由调用方保证——两画布前缀不同）。
    @ViewBuilder
    func accessibilityIdentifierPrefix(_ prefix: String?, suffix: String) -> some View {
        if let prefix {
            self.accessibilityIdentifier("\(prefix).\(suffix)")
        } else {
            self
        }
    }
}
