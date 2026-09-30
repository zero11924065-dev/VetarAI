//
//  VDialog.swift
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

//  弹窗基础设施（对齐 Dialog.tsx 的交互语义）：
//    · 遮罩点击 = 取消；Esc = 取消；Enter = 确认
//    · danger 确认按钮红底
//    · 可选勾选项（仅确认时回传勾选值）
//    · 附加按钮（授权弹窗的「本会话不再询问 / 永久允许」走这里，点下 = 确认 + 记忆）
//
//  用法（面板）：
//    let ok = await DialogCenter.shared.confirm(title: "删除", message: "…", danger: true)
//  RootView 已挂 DialogHostView overlay，面板无需关心呈现。
//

import SwiftUI

// MARK: - 模型

public struct VDialogButton: Identifiable {
    public enum Role { case primary, secondary, danger }
    public let id: String
    public let title: String
    public let role: Role
    /// 点下该按钮时回传的值（默认 = id）
    public let value: String

    public init(_ title: String, role: Role = .secondary, value: String? = nil) {
        self.id = value ?? title
        self.title = title
        self.role = role
        self.value = value ?? title
    }
}

public struct VDialogSpec {
    public var title: String
    public var message: String
    public var buttons: [VDialogButton]
    /// 可选勾选框（仅确认路径回传）
    public var checkboxLabel: String?
    public var checkboxDefault: Bool = false
    /// 文本输入模式（重命名等 prompt 场景；非 nil 时弹窗带输入框，确认返回输入文本）
    public var promptDefault: String?
    public var promptPlaceholder: String?
    /// 取消语义按钮的 value（Esc / 点遮罩 / 取消按钮都回这个）
    public var cancelValue: String = "__cancel__"

    public init(title: String, message: String, buttons: [VDialogButton],
                checkboxLabel: String? = nil, checkboxDefault: Bool = false) {
        self.title = title
        self.message = message
        self.buttons = buttons
        self.checkboxLabel = checkboxLabel
        self.checkboxDefault = checkboxDefault
    }
}

// MARK: - 中心（命令式 async API）

@MainActor
public final class DialogCenter: ObservableObject {
    public static let shared = DialogCenter()

    @Published public private(set) var current: VDialogSpec?
    /// 勾选框当前值（确认路径读取）
    @Published public var checkboxChecked: Bool = false
    /// 文本输入当前值（prompt 模式；确认路径读取）
    @Published public var promptText: String = ""

    private var continuation: CheckedContinuation<String, Never>?

    /// 通用弹窗：返回被点按钮的 value；取消返回 cancelValue。
    public func present(_ spec: VDialogSpec) async -> String {
        // 防御：已有弹窗时先完结旧弹窗（取消语义）
        continuation?.resume(returning: spec.cancelValue)
        checkboxChecked = spec.checkboxDefault
        promptText = spec.promptDefault ?? ""
        return await withCheckedContinuation { cont in
            self.continuation = cont
            self.current = spec
        }
    }

    /// 输入弹窗（对齐 Dialog.tsx promptDialog）：确认返回输入文本（去首尾空白），取消返回 nil。
    public func prompt(title: String, message: String = "", defaultValue: String = "",
                       placeholder: String = "",
                       confirmText: String = "保存", cancelText: String = "取消") async -> String? {
        var spec = VDialogSpec(
            title: title, message: message,
            buttons: [VDialogButton(cancelText, role: .secondary, value: "cancel"),
                      VDialogButton(confirmText, role: .primary, value: "ok")]
        )
        spec.promptDefault = defaultValue
        spec.promptPlaceholder = placeholder
        let v = await present(spec)
        guard v == "ok" else { return nil }
        let t = promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// 确认框（语义替换 NSAlert confirm）：确认返回 true，否则 false。
    public func confirm(title: String, message: String,
                        confirmText: String = "确认", cancelText: String = "取消",
                        danger: Bool = false,
                        checkboxLabel: String? = nil, checkboxDefault: Bool = false) async -> Bool {
        let spec = VDialogSpec(
            title: title, message: message,
            buttons: [VDialogButton(cancelText, role: .secondary, value: "cancel"),
                      VDialogButton(confirmText, role: danger ? .danger : .primary, value: "ok")],
            checkboxLabel: checkboxLabel, checkboxDefault: checkboxDefault
        )
        return await present(spec) == "ok"
    }

    /// 单按钮提示。
    public func alert(title: String, message: String, buttonText: String = "知道了") async {
        _ = await present(VDialogSpec(title: title, message: message,
                                      buttons: [VDialogButton(buttonText, role: .primary, value: "ok")]))
    }

    /// 按钮点击（host view 调用）。
    public func tap(_ button: VDialogButton) {
        finish(button.value)
    }

    /// Esc / 遮罩点击（host view 调用）。
    public func cancel() {
        guard let spec = current else { return }
        finish(spec.cancelValue)
    }

    private func finish(_ value: String) {
        current = nil
        let cont = continuation
        continuation = nil
        cont?.resume(returning: value)
    }
}

// MARK: - 宿主视图（挂 RootView overlay）

public struct DialogHostView: View {
    @ObservedObject var center: DialogCenter

    @MainActor public init(center: DialogCenter = .shared) { self.center = center }

    public var body: some View {
        if let spec = center.current {
            VDialogOverlay(spec: spec, center: center)
                .transition(.opacity)
        }
    }
}

/// 遮罩 + 卡片（授权弹窗复用同一视觉）。
public struct VDialogOverlay<Buttons: View>: View {
    public let spec: VDialogSpec
    @ObservedObject public var center: DialogCenter
    @ViewBuilder public var extraContent: () -> Buttons
    /// prompt 模式自动聚焦（现状 promptDialog 挂载即聚焦输入框；否则键盘输入会漏到背后的 composer）
    @FocusState private var promptFocused: Bool

    public init(spec: VDialogSpec, center: DialogCenter,
                @ViewBuilder extraContent: @escaping () -> Buttons = { EmptyView() }) {
        self.spec = spec
        self.center = center
        self.extraContent = extraContent
    }

    public var body: some View {
        ZStack {
            Color.black.opacity(0.36)
                .ignoresSafeArea()
                .onTapGesture { center.cancel() }
            VStack(alignment: .leading, spacing: 0) {
                Text(spec.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(VTheme.textPrimary)
                    .padding(.bottom, 12)
                Text(spec.message)
                    .font(VTheme.Typo.body)
                    .foregroundStyle(VTheme.textSecondary)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if let label = spec.checkboxLabel {
                    Toggle(label, isOn: $center.checkboxChecked)
                        .font(VTheme.Typo.caption)
                        .foregroundStyle(VTheme.textSecondary)
                        .padding(.top, 12)
                }
                if spec.promptDefault != nil {
                    TextField(spec.promptPlaceholder ?? "", text: $center.promptText)
                        .textFieldStyle(.roundedBorder)
                        .font(VTheme.Typo.body)
                        .padding(.top, 12)
                        .accessibilityIdentifier("dialogPromptField")
                        .focused($promptFocused)
                        .onAppear { promptFocused = true }
                        .onSubmit {
                            if let ok = spec.buttons.first(where: { $0.value == "ok" }) {
                                center.tap(ok)
                            }
                        }
                }
                extraContent()
                HStack(spacing: 8) {
                    Spacer()
                    ForEach(spec.buttons) { button in
                        Button(button.title) { center.tap(button) }
                            .buttonStyle(style(for: button.role))
                            .accessibilityIdentifier("dialogButton.\(button.value)")
                    }
                }
                .padding(.top, 22)
            }
            .padding(EdgeInsets(top: 22, leading: 24, bottom: 22, trailing: 24))
            .frame(width: 420)
            .background(VTheme.bgCard, in: RoundedRectangle(cornerRadius: VTheme.Radius.l))
            .overlay(RoundedRectangle(cornerRadius: VTheme.Radius.l).stroke(VTheme.borderSubtle))
            .shadow(color: .black.opacity(0.12), radius: 15, y: 5)
        }
        // Esc = 取消（隐藏按钮承载键盘语义）
        .background(
            Button("") { center.cancel() }
                .keyboardShortcut(.cancelAction)
                .hidden()
        )
    }

    private func style(for role: VDialogButton.Role) -> AnyButtonStyle {
        switch role {
        case .primary: return AnyButtonStyle(VPrimaryButtonStyle())
        case .secondary: return AnyButtonStyle(VSecondaryButtonStyle())
        case .danger: return AnyButtonStyle(VPrimaryButtonStyle(danger: true))
        }
    }
}

/// 类型擦除 ButtonStyle（弹窗内异构按钮统一用）。
public struct AnyButtonStyle: ButtonStyle {
    private let _makeBody: (Configuration) -> AnyView
    public init<S: ButtonStyle>(_ style: S) {
        _makeBody = { AnyView(style.makeBody(configuration: $0)) }
    }
    public func makeBody(configuration: Configuration) -> AnyView {
        _makeBody(configuration)
    }
}
