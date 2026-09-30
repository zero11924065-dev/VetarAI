//
//  VCallout.swift
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

//  提示条组件（对齐 theme.ts calloutStyle）：info / success / warn / error 四类色块。
//

import SwiftUI

public enum VCalloutKind {
    case info, success, warn, error

    var icon: String {
        switch self {
        case .info: return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .warn: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }
    var background: Color {
        switch self {
        case .info: return VTheme.accentBgSoft
        case .success: return VTheme.okBg
        case .warn: return VTheme.warnBg
        case .error: return VTheme.dangerBg
        }
    }
    var border: Color {
        switch self {
        case .info: return VTheme.accentBorder
        case .success: return VTheme.okBorder
        case .warn: return VTheme.warnBorder
        case .error: return VTheme.dangerBorder
        }
    }
    var foreground: Color {
        switch self {
        case .info: return VTheme.accentTextDeep
        case .success: return VTheme.okText
        case .warn: return VTheme.warnText
        case .error: return VTheme.dangerText
        }
    }
}

public struct VCallout: View {
    public let kind: VCalloutKind
    public let text: String

    public init(_ kind: VCalloutKind, _ text: String) {
        self.kind = kind
        self.text = text
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: kind.icon)
                .font(.system(size: 12))
                .padding(.top, 1)
            Text(text)
                .font(VTheme.Typo.body)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundStyle(kind.foreground)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(kind.background, in: RoundedRectangle(cornerRadius: VTheme.Radius.s))
        .overlay(RoundedRectangle(cornerRadius: VTheme.Radius.s).stroke(kind.border))
    }
}
