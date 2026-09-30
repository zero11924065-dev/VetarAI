//
//  ModelOptionsEditorView.swift
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

//  每模型推理参数编辑器（SwiftUI 移植，对标 ModelOptionsEditor.tsx）：
//    · 后端门禁提示条（OpenAI 兼容 / 模型包两种文案逐字）
//    · 已配置模型折叠卡：徽标计数 + 展开编辑 + 移除该模型配置
//    · 参数行：标签 + 取值范围 + 「该后端不支持」警示 + 已设对勾 + 输入框
//      （草稿模式：onChange 只写草稿，Enter/blur 提交；非法值草稿保留不回弹）
//  本组件只编辑**已配置**的模型；新增配置走推理面板模型列表行的「参数」按钮。
//

import SwiftUI

public struct ModelOptionsEditorView: View {
    @ObservedObject var vm: ModelOptionsEditorViewModel
    /// 焦点态（focusKey 防外部刷新覆盖正在输入的字段）
    @FocusState private var focusedKey: String?

    public init(vm: ModelOptionsEditorViewModel) {
        self.vm = vm
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ── 后端门禁提示（文案逐字对齐 TSX 两条 callout）──
            if !vm.isOllama && !vm.isModelPackage {
                VCallout(.info, "当前为 OpenAI 兼容后端：num_ctx 与 top_k 不支持（已置灰），repeat_penalty 会自动映射为 frequency_penalty、num_predict 映射为 max_tokens。")
                    .padding(.bottom, 10)
            }
            if !vm.isOllama && vm.isModelPackage {
                VCallout(.info, "当前为模型包后端：num_ctx 是上下文上限——懒加载开启时先以低档启动，上下文膨胀自动升档至此值；top_k 不支持（已置灰）。")
                    .padding(.bottom, 10)
            }

            if vm.configuredModels.isEmpty {
                Text("（尚未为任何模型配置参数——不配置时完全沿用模型自身默认值，行为与升级前一致）")
                    .font(VTheme.Typo.caption)
                    .foregroundStyle(VTheme.textTertiary)
                    .padding(.bottom, 8)
            }

            ForEach(vm.configuredModels, id: \.self) { name in
                modelCard(name)
            }

            Text("要为新模型配置参数，请在上方「模型列表」里点该模型的「参数」按钮。")
                .font(VTheme.Typo.micro)
                .foregroundStyle(VTheme.textTertiary)
                .padding(.top, 2)

            if let err = vm.errorMessage {
                VCallout(.error, err).padding(.top, 8)
            }
        }
    }

    // MARK: - 单模型折叠卡

    private func modelCard(_ name: String) -> some View {
        let open = vm.expandedModel == name
        let count = vm.configuredCount(model: name)
        return VStack(alignment: .leading, spacing: 0) {
            // 头部行（点击展开/收起）
            HStack(spacing: 6) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 11))
                    .foregroundStyle(VTheme.textTertiary)
                Text(name)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(VTheme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                Text(count > 0 ? "\(count) 项已设" : "全部默认")
                    .font(VTheme.Typo.micro)
                    .foregroundStyle(count > 0 ? VTheme.textSecondary : VTheme.textTertiary)
                Image(systemName: open ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10))
                    .foregroundStyle(VTheme.textTertiary)
                Button {
                    vm.removeModel(name)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundStyle(VTheme.textTertiary)
                }
                .buttonStyle(.plain)
                .disabled(vm.busy)
                .help("移除该模型的全部参数配置")
                .accessibilityIdentifier("modelOptions.remove.\(name)")
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .contentShape(Rectangle())
            .onTapGesture { vm.expandedModel = open ? nil : name }

            if open {
                Divider().overlay(VTheme.borderSubtle)
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(ModelOptionParams.all, id: \.key) { def in
                        paramRow(model: name, def: def)
                    }
                    Text("清空某项 = 该参数回落模型默认值。输入后按 Enter 或移开焦点保存；越界/非法值不会保存，已输入内容保留。")
                        .font(VTheme.Typo.micro)
                        .foregroundStyle(VTheme.textTertiary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
        }
        .background(VTheme.bgCard, in: RoundedRectangle(cornerRadius: VTheme.Radius.s))
        .overlay(RoundedRectangle(cornerRadius: VTheme.Radius.s).stroke(VTheme.borderSubtle))
        .padding(.bottom, 8)
    }

    // MARK: - 参数行（草稿受控 + Enter/blur 提交）

    private func paramRow(model: String, def: ModelOptionParamDef) -> some View {
        let disabled = vm.isDisabled(def)
        let key = ModelOptionsEditorViewModel.fieldKey(model: model, key: def.key)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(def.label)
                    .font(VTheme.Typo.caption)
                    .foregroundStyle(VTheme.textPrimary)
                if let min = def.min, let max = def.max {
                    Text("（\(ModelOptionsEditorViewModel.formatBound(min))~\(ModelOptionsEditorViewModel.formatBound(max))）")
                        .font(VTheme.Typo.micro)
                        .foregroundStyle(VTheme.textTertiary)
                }
                if disabled {
                    Text("该后端不支持")
                        .font(VTheme.Typo.micro)
                        .foregroundStyle(VTheme.warnText)
                }
                if vm.hasSavedValue(model: model, def: def) && !disabled {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(VTheme.ok)
                }
            }
            TextField(def.placeholder, text: Binding(
                get: { vm.displayValue(model: model, def: def) },
                set: { vm.editDraft(model: model, def: def, text: $0) }
            ))
            .textFieldStyle(.plain)
            .font(.system(size: 12, design: .monospaced))
            .vInputStyle()
            .disabled(vm.busy || disabled)
            .focused($focusedKey, equals: key)
            .onSubmit { vm.commit(model: model, def: def) }
            .accessibilityIdentifier("modelOptions.field.\(model).\(def.key)")
            .onChange(of: focusedKey) { old, now in
                // 聚焦 = 标记防外部刷新覆盖；失焦 = blur 提交（对齐 onFocus/onBlur）
                if now == key {
                    vm.beginFocus(model: model, def: def)
                } else if old == key {
                    vm.endFocus(model: model, def: def)
                }
            }
            Text(def.hint)
                .font(VTheme.Typo.micro)
                .foregroundStyle(VTheme.textTertiary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .opacity(disabled ? 0.5 : 1)
    }
}
