//
//  WorkflowEditorView.swift
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

//  工作流节点配置表单（对标 subagent/renderer/src/panels/WorkflowEditor.tsx，494 行）：
//    · 选中画布节点后右侧编辑属性；支持新增节点 / 连线增删 / 删除节点（start 除外）
//    · 13 类节点表单逐分支对齐（推理/工具/条件/并行/循环/审批/文件三件套/文本输出/
//      变量赋值/代码执行/消息回复/结束），节点类型与后端 schema.py NODE_TYPES 一致
//    · 文件/文件夹选择用 NSOpenPanel（替代 Electron bridge chooseInputFile/chooseInputDir）
//    · 全部修改经 vm.mutateDefinition 收口置脏（对齐 onDefChange → dirty）
//    · V3 复核：编辑器 320 固定列保持（U1 fixedSize）；「连线」区自 U1 起即两行布局
//      （第一行 起点→终点 Picker 各限宽 135，第二行 分支标签+连线按钮，
//      对齐 WorkflowEditor.tsx:466-481 双 flex 行），296 内容列内完整可见，无需再改
//

import SwiftUI
import AppKit

public struct WorkflowEditorView: View {
    @ObservedObject var vm: WorkflowPanelViewModel

    @State private var newNodeType = "inference"
    @State private var edgeFrom = ""
    @State private var edgeTo = ""
    @State private var edgeWhen = ""

    public init(vm: WorkflowPanelViewModel) {
        self.vm = vm
    }

    private var node: WorkflowNode? {
        vm.definition.node(id: vm.selectedNodeId ?? "")
    }

    public var body: some View {
        VStack(spacing: 0) {
            // 头行：标题 + 关闭
            HStack {
                Text("节点配置")
                    .font(VTheme.Typo.panelTitle)
                Spacer()
                Button { vm.selectedNodeId = nil } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.vGhost)
                .controlSize(.small)
                .accessibilityIdentifier("workflowEditorClose")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let node {
                        nodeForm(node)
                    } else {
                        Text("点击画布中的节点进行配置，或在下方新增节点。")
                            .font(VTheme.Typo.caption)
                            .foregroundStyle(VTheme.textTertiary)
                            .padding(.vertical, 12)
                    }
                    addNodeSection
                    edgesSection
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 16)
                // U1：内容列撑满编辑器宽度并左对齐，配合下方 Picker 限宽防溢出
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 320)
        // U1 防挤压（对齐 WorkflowEditor.tsx width:320 + flexShrink:0 语义）：
        // 超载时保持 320，由中列画布吸收压缩
        .fixedSize(horizontal: true, vertical: false)
        .background(VTheme.bgCard)
        // U1 兜底（对齐 WorkflowEditor.tsx overflow:hidden）：超宽内容裁切而非越界绘制
        .clipped()
        // DBG-160：容器不挂 id（内有 workflowNodeLabel/Delete/Model 等叶子 id）
    }

    // MARK: - 节点表单（选中节点时）

    @ViewBuilder
    private func nodeForm(_ node: WorkflowNode) -> some View {
        fieldLabel("节点名称")
        TextField("", text: Binding(
            get: { node.label ?? "" },
            set: { vm.patchNode(id: node.id, patch: ["label": .string($0)]) }))
            .vInputStyle()
            .accessibilityIdentifier("workflowNodeLabel")

        fieldLabel("节点类型")
        Text("\(node.type)（id: \(node.id)）")
            .font(VTheme.Typo.caption)
            .foregroundStyle(VTheme.textTertiary)

        switch node.type {
        case "inference": inferenceForm(node)
        case "tool": toolForm(node)
        case "condition": conditionForm(node)
        case "parallel": parallelForm(node)
        case "loop": loopForm(node)
        case "approval": approvalForm(node)
        case "file_input": fileInputForm(node)
        case "file_read": fileReadForm(node)
        case "file_output": fileOutputForm(node)
        case "text_output": textOutputForm(node)
        case "variable_set": variableSetForm(node)
        case "code": codeForm(node)
        case "reply": replyForm(node)
        case "end": endForm(node)
        default: EmptyView()
        }

        if node.type != "start" {
            Button {
                vm.removeNode(id: node.id)
            } label: {
                Label("删除此节点", systemImage: "trash")
                    .font(VTheme.Typo.caption)
            }
            .buttonStyle(.vDanger)
            .controlSize(.small)
            .padding(.top, 14)
            .accessibilityIdentifier("workflowNodeDelete")
        }
    }

    // MARK: 推理

    @ViewBuilder
    private func inferenceForm(_ node: WorkflowNode) -> some View {
        fieldLabel("模型")
        Picker("", selection: Binding(
            get: { node.props["model"]?.string ?? "" },
            set: { vm.patchNode(id: node.id, patch: ["model": .string($0)]) })) {
            Text("（选择模型）").tag("")
            ForEach(vm.models, id: \.self) { Text($0).tag($0) }
        }
        .labelsHidden()
        .accessibilityIdentifier("workflowNodeModel")

        fieldLabel("提示词（可用 {{params.名称}}、{{item}} 等变量）")
        textArea(Binding(
            get: { node.props["prompt"]?.string ?? "" },
            set: { vm.patchNode(id: node.id, patch: ["prompt": .string($0)]) }),
            minHeight: 80)

        fieldLabel("图片变量（可选，如 {{params.images}}）")
        TextField("留空 = 无图片", text: Binding(
            get: { node.props["images"]?.string ?? "" },
            // 对齐 TSX：空串 → 删除该键（undefined 语义）
            set: { vm.patchNode(id: node.id, patch: ["images": $0.isEmpty ? nil : .string($0)]) }))
            .vInputStyle()

        fieldLabel("失败重试次数")
        numberField(value: node.props["retry"]?.int.map(Int.init) ?? 0, range: 0...5) { v in
            vm.patchNode(id: node.id, patch: ["retry": .int(Int64(v))])
        }
    }

    // MARK: 工具

    @ViewBuilder
    private func toolForm(_ node: WorkflowNode) -> some View {
        fieldLabel("工具名（write_file / read_file / list_dir / create_dir）")
        TextField("", text: Binding(
            get: { node.props["tool"]?.string ?? "" },
            set: { vm.patchNode(id: node.id, patch: ["tool": .string($0)]) }))
            .vInputStyle()

        fieldLabel("参数（JSON，值可用 {{...}} 变量）")
        // JSON 中途输入不强制合法（对齐 TSX try/catch 分支）：本地文本态，合法才落定义
        ArgsJSONEditor(node: node, vm: vm)
            .id("args-\(node.id)")
    }

    // MARK: 条件分支

    @ViewBuilder
    private func conditionForm(_ node: WorkflowNode) -> some View {
        let isDynamic = node.props["model"]?.string != nil
        fieldLabel("判断方式")
        HStack(spacing: 8) {
            Button("静态匹配") {
                // 对齐 TSX：静态 = 移除 model/prompt 键
                vm.patchNode(id: node.id, patch: ["model": nil, "prompt": nil])
            }
            .buttonStyle(.vSecondary)
            .controlSize(.small)
            .tint(isDynamic ? nil : VTheme.accent)
            Button("动态裁判（模型判定）") {
                vm.patchNode(id: node.id, patch: [
                    "model": .string(node.props["model"]?.string ?? vm.models.first ?? ""),
                    "prompt": .string(node.props["prompt"]?.string ?? ""),
                ])
            }
            .buttonStyle(.vSecondary)
            .controlSize(.small)
            .tint(isDynamic ? VTheme.accent : nil)
        }

        if isDynamic {
            fieldLabel("裁判模型")
            Picker("", selection: Binding(
                get: { node.props["model"]?.string ?? "" },
                set: { vm.patchNode(id: node.id, patch: ["model": .string($0)]) })) {
                ForEach(vm.models, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            fieldLabel("判定提示词（输出内容 = 分支 when 标签）")
            textArea(Binding(
                get: { node.props["prompt"]?.string ?? "" },
                set: { vm.patchNode(id: node.id, patch: ["prompt": .string($0)]) }),
                minHeight: 60)
            hintText("连线 when 填模型输出的分支名（如\"是\"/\"否\"），动态分支。")
        } else {
            let match = node.props["match"]?.object ?? [:]
            let op = match["operator"]?.string ?? "contains"
            fieldLabel("匹配变量（如 {{n1.output}}）")
            TextField("", text: Binding(
                get: { match["variable"]?.string ?? "" },
                set: { vm.patchNode(id: node.id, patch: ["match": .object(merging(match, ["variable": .string($0)]))]) }))
                .vInputStyle()
            fieldLabel("运算符")
            Picker("", selection: Binding(
                get: { op },
                set: { vm.patchNode(id: node.id, patch: ["match": .object(merging(match, ["operator": .string($0)]))]) })) {
                ForEach(WorkflowNodeTypes.conditionOps, id: \.value) { Text($0.label).tag($0.value) }
            }
            .labelsHidden()
            if !WorkflowNodeTypes.opsWithoutValue.contains(op) {
                fieldLabel("匹配值")
                TextField("", text: Binding(
                    get: { match["value"]?.string ?? "" },
                    set: { vm.patchNode(id: node.id, patch: ["match": .object(merging(match, ["value": .string($0)]))]) }))
                    .vInputStyle()
            }
            hintText("命中走 when=\"true\" 的边，不命中走 when=\"false\"。")
        }
    }

    // MARK: 并行

    @ViewBuilder
    private func parallelForm(_ node: WorkflowNode) -> some View {
        fieldLabel("并行分支（节点 id，逗号分隔）")
        TextField("", text: Binding(
            get: { (node.props["branches"]?.stringArray ?? []).joined(separator: ", ") },
            set: { raw in
                // 对齐 TSX split(/[,，]/) 去空白过滤
                let parts = raw.components(separatedBy: CharacterSet(charactersIn: ",，"))
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                vm.patchNode(id: node.id, patch: ["branches": .array(parts.map { .string($0) })])
            }))
            .vInputStyle()
        hintText("可选：\(nodeIdsDescription)")
    }

    // MARK: 循环（0.2.4 W2/W9：执行模式与等待策略）

    @ViewBuilder
    private func loopForm(_ node: WorkflowNode) -> some View {
        fieldLabel("列表变量（如 {{文件输入.output}}）")
        TextField("", text: Binding(
            get: { node.props["items"]?.string ?? "" },
            set: { vm.patchNode(id: node.id, patch: ["items": .string($0)]) }))
            .vInputStyle()
        fieldLabel("循环体节点 id（顺序链用逗号分隔，内部可用 {{item}}）")
        TextField("", text: Binding(
            get: { node.props["branch"]?.string ?? "" },
            set: { vm.patchNode(id: node.id, patch: ["branch": .string($0.trimmingCharacters(in: .whitespaces))]) }))
            .vInputStyle()
        hintText("可选：\(nodeIdsDescription)")

        fieldLabel("分批大小（每轮处理几项，如一次 2-3 张图；留空或 1 = 逐项）")
        optionalNumberField(value: node.props["batch_size"]?.int.map(Int.init), range: 1...50, placeholder: "1") { v in
            vm.patchNode(id: node.id, patch: ["batch_size": v.map { .int(Int64($0)) }])
        }
        hintText("分批时 {{item}} 为当批列表、{{batch}} 始终为当批列表、{{item_index}} 为批序号。")

        fieldLabel("失败策略")
        Picker("", selection: Binding(
            get: { node.props["fail_policy"]?.string ?? "abort" },
            set: { vm.patchNode(id: node.id, patch: ["fail_policy": .string($0)]) })) {
            Text("中止循环（遇到失败批立即停止，默认）").tag("abort")
            // S4-1 2026-09-30 真因：「输出占位」是工程黑话，用户看不懂；tag 值不动。
            Text("跳过失败批继续（该批输出为空，继续处理后续批）").tag("skip")
        }
        .labelsHidden()

        fieldLabel("允许失败批数上限（0 = 不允许失败；仅\"跳过\"策略生效）")
        numberField(value: node.props["max_failures"]?.int.map(Int.init) ?? 0, range: 0...100) { v in
            vm.patchNode(id: node.id, patch: ["max_failures": .int(Int64(v))])
        }

        fieldLabel("批间等待（毫秒，0 = 不等待；大批量推理建议 500~2000 给模型喘息）")
        numberField(value: node.props["wait_ms"]?.int.map(Int.init) ?? 0, range: 0...1_000_000) { v in
            vm.patchNode(id: node.id, patch: ["wait_ms": .int(Int64(v))])
        }
    }

    // MARK: 人工审批

    @ViewBuilder
    private func approvalForm(_ node: WorkflowNode) -> some View {
        fieldLabel("审批提示（可用变量）")
        textArea(Binding(
            get: { node.props["message"]?.string ?? "" },
            set: { vm.patchNode(id: node.id, patch: ["message": .string($0)]) }),
            minHeight: 60)
    }

    // MARK: 文件输入

    @ViewBuilder
    private func fileInputForm(_ node: WorkflowNode) -> some View {
        fieldLabel("本机路径（文件或文件夹，支持 {{params.名称}}）")
        pathRow(node: node, key: "path", placeholder: "/Users/你/材料/聊天记录", pickDir: true, pickFile: true)
        fieldLabel("读取扩展名（白名单：只读这些类型，逗号分隔；留空 = 读全部）")
        TextField("jpg, png, jpeg", text: Binding(
            get: { node.props["extensions"]?.string ?? "" },
            set: { vm.patchNode(id: node.id, patch: ["extensions": .string($0)]) }))
            .vInputStyle()
        Toggle("文件夹时递归搜索子目录", isOn: Binding(
            get: { node.props["recursive"]?.bool ?? false },
            set: { vm.patchNode(id: node.id, patch: ["recursive": .bool($0)]) }))
            .font(VTheme.Typo.caption)
            .padding(.top, 10)
        hintText("输出：文件路径列表，可用循环节点 + {{item}} 逐个处理。非图片文件（如音频）不会作为图片传给视觉模型。")
    }

    // MARK: 文件读取

    @ViewBuilder
    private func fileReadForm(_ node: WorkflowNode) -> some View {
        fieldLabel("本机路径（文件或文件夹，支持 {{变量}}）")
        pathRow(node: node, key: "path", placeholder: "/Users/你/材料/聊天文本", pickDir: true, pickFile: true)
        fieldLabel("读取扩展名（白名单：只读这些类型，如 md, txt；留空 = 读全部）")
        TextField("md, txt", text: Binding(
            get: { node.props["extensions"]?.string ?? "" },
            set: { vm.patchNode(id: node.id, patch: ["extensions": .string($0)]) }))
            .vInputStyle()
        fieldLabel("文件间分隔模板（留空 = 默认\"=== 文件名 ===\"；可用 {{filename}}）")
        TextField("=== {{filename}} ===", text: Binding(
            get: { node.props["separator"]?.string ?? "" },
            set: { vm.patchNode(id: node.id, patch: ["separator": .string($0)]) }))
            .vInputStyle()
        hintText("输出：拼接后的全部文件内容文本，供推理/分析节点消费（纯本地读取，不联网）。")
    }

    // MARK: 文件输出

    @ViewBuilder
    private func fileOutputForm(_ node: WorkflowNode) -> some View {
        fieldLabel("保存目录（支持 {{变量}}）")
        pathRow(node: node, key: "dir", placeholder: "/Users/你/材料/聊天文本", pickDir: true, pickFile: false)
        fieldLabel("文件名（支持 {{item}} / {{item_index}} / {{节点.output}}）")
        TextField("{{item_index}}.md", text: Binding(
            get: { node.props["filename"]?.string ?? "" },
            set: { vm.patchNode(id: node.id, patch: ["filename": .string($0)]) }))
            .vInputStyle()
        fieldLabel("文件内容（支持 {{变量}}）")
        textArea(Binding(
            get: { node.props["content"]?.string ?? "" },
            set: { vm.patchNode(id: node.id, patch: ["content": .string($0)]) }),
            minHeight: 70, mono: true, placeholder: "{{ocr.output}}")
        hintText("循环节点内使用时，每一轮写入一个文件（文件名用 {{item_index}} 或 {{item}} 区分）。")
    }

    // MARK: TS-121（0.3.1 补遗1）：文本输出 / 变量赋值 / 代码执行 / 消息回复

    @ViewBuilder
    private func textOutputForm(_ node: WorkflowNode) -> some View {
        fieldLabel("内容模板（支持 {{节点.output}} / {{params.名称}} / {{变量名}}）")
        textArea(Binding(
            get: { node.props["template"]?.string ?? "" },
            set: { vm.patchNode(id: node.id, patch: ["template": .string($0)]) }),
            minHeight: 80, placeholder: "汇总：\n{{n1.output}}")
        hintText("渲染结果作为本节点输出，可继续流转到下游或作为结束结果（不落盘）。")
    }

    @ViewBuilder
    private func variableSetForm(_ node: WorkflowNode) -> some View {
        fieldLabel("变量名（下游用 {{变量名}} 引用，不能含 . 或 /）")
        TextField("total", text: Binding(
            get: { node.props["name"]?.string ?? "" },
            set: { vm.patchNode(id: node.id, patch: ["name": .string($0)]) }))
            .vInputStyle()
        fieldLabel("值（整串 {{x.output}} = 保持原值类型；混合文本 = 渲染为字符串）")
        TextField("{{n1.output}}", text: Binding(
            get: { node.props["value"]?.string ?? "" },
            set: { vm.patchNode(id: node.id, patch: ["value": .string($0)]) }))
            .vInputStyle()
    }

    @ViewBuilder
    private func codeForm(_ node: WorkflowNode) -> some View {
        fieldLabel("Python 代码（本机执行，不联网）")
        textArea(Binding(
            get: { node.props["code"]?.string ?? "" },
            set: { vm.patchNode(id: node.id, patch: ["code": .string($0)]) }),
            minHeight: 120, mono: true,
            placeholder: "# 读上游：variables['n1']['output'] 或自定义变量 variables['total']\nresult = '处理完成'")
        fieldLabel("执行超时（秒，默认 30，上限 300；超时节点判失败、工作流继续）")
        numberField(value: node.props["timeout_s"]?.int.map(Int.init) ?? 30, range: 1...300) { v in
            vm.patchNode(id: node.id, patch: ["timeout_s": .int(Int64(v))])
        }
        hintText("约定：用 variables 字典读上游输出/变量；把结果赋给 result 即本节点输出。代码以本应用权限在本机运行。")
    }

    @ViewBuilder
    private func replyForm(_ node: WorkflowNode) -> some View {
        fieldLabel("回复内容（支持 {{变量}}，执行时作为一条助手消息推给会话）")
        textArea(Binding(
            get: { node.props["text"]?.string ?? "" },
            set: { vm.patchNode(id: node.id, patch: ["text": .string($0)]) }),
            minHeight: 70, placeholder: "已完成：{{n1.output}}")
    }

    // MARK: 结束

    @ViewBuilder
    private func endForm(_ node: WorkflowNode) -> some View {
        fieldLabel("结果引用（如 {{n1.output}}，留空 = 无结果）")
        TextField("", text: Binding(
            get: { node.props["output"]?.string ?? "" },
            // 对齐 TSX：空串 → 删除该键（undefined 语义）
            set: { vm.patchNode(id: node.id, patch: ["output": $0.isEmpty ? nil : .string($0)]) }))
            .vInputStyle()
    }

    // MARK: - 新增节点区

    private var addNodeSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("新增节点")
                .font(VTheme.Typo.caption.weight(.semibold))
            HStack(spacing: 6) {
                Picker("", selection: $newNodeType) {
                    ForEach(WorkflowNodeTypes.addOptions, id: \.value) { Text($0.label).tag($0.value) }
                }
                .labelsHidden()
                // U1：macOS Picker 桥接 NSPopUpButton 按最长菜单项定宽、不截断——
                // 显式限宽使其截断收缩（对齐 TSX select 天然收缩），防溢出右边界
                .frame(maxWidth: 210)
                Button("添加") { vm.addNode(type: newNodeType) }
                    .buttonStyle(.vPrimary)
                    .controlSize(.small)
                    .accessibilityIdentifier("workflowAddNode")
            }
        }
        .padding(.top, 16)
        .overlay(alignment: .top) { Divider().padding(.top, -8) }
    }

    // MARK: - 连线区

    private var edgesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("连线")
                .font(VTheme.Typo.caption.weight(.semibold))
            HStack(spacing: 6) {
                Picker("", selection: $edgeFrom) {
                    Text("起点…").tag("")
                    ForEach(vm.definition.nodes) { Text($0.label ?? $0.id).tag($0.id) }
                }
                .labelsHidden()
                .font(VTheme.Typo.micro)
                // U1：菜单项为用户可长命名的节点 label，NSPopUpButton 按最长项
                // 定宽不截断——显式限宽（两 Picker + 箭头均分 296pt 内容宽）
                .frame(maxWidth: 135)
                Text("→").foregroundStyle(VTheme.textTertiary)
                Picker("", selection: $edgeTo) {
                    Text("终点…").tag("")
                    ForEach(vm.definition.nodes) { Text($0.label ?? $0.id).tag($0.id) }
                }
                .labelsHidden()
                .font(VTheme.Typo.micro)
                .frame(maxWidth: 135)
            }
            HStack(spacing: 6) {
                TextField("分支标签 when（可选）", text: $edgeWhen)
                    .vInputStyle()
                    .font(VTheme.Typo.micro)
                Button("连线") {
                    if vm.addEdge(from: edgeFrom, to: edgeTo, when: edgeWhen) {
                        edgeWhen = ""     // 对齐 TSX：添加成功才清 when 输入
                    }
                }
                .buttonStyle(.vPrimary)
                .controlSize(.small)
                .accessibilityIdentifier("workflowAddEdge")
            }
            ForEach(Array(vm.definition.edges.enumerated()), id: \.offset) { idx, e in
                HStack(spacing: 4) {
                    Text("\(e.from) → \(e.to)\(e.when.map { "（\($0)）" } ?? "")")
                        .font(VTheme.Typo.micro)
                        .foregroundStyle(VTheme.textSecondary)
                    Spacer()
                    Button("删除") { vm.removeEdge(at: idx) }
                        .buttonStyle(.vGhost)
                        .controlSize(.mini)
                        .foregroundStyle(VTheme.dangerText)
                        .accessibilityIdentifier("workflowEdgeDelete.\(idx)")
                }
            }
        }
        .padding(.top, 14)
        .overlay(alignment: .top) { Divider().padding(.top, -8) }
    }

    // MARK: - 小组件

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(VTheme.Typo.caption.weight(.medium))
            .foregroundStyle(VTheme.textSecondary)
            .padding(.top, 10)
            .padding(.bottom, 4)
    }

    private func hintText(_ text: String) -> some View {
        Text(text)
            .font(VTheme.Typo.micro)
            .foregroundStyle(VTheme.textTertiary)
            .padding(.top, 4)
    }

    private func textArea(_ text: Binding<String>, minHeight: CGFloat,
                          mono: Bool = false, placeholder: String = "") -> some View {
        // P0-C 根治（2026-09-22 业主点名复发）：换 VPlaceholderTextEditor——
        // NSTextView 封装 + ComposerSyncPolicy 内容口径（含 IME marked text）；
        // 原 SwiftUI TextEditor + isEmpty 自绘占位在组字期与拼音重叠（同病同修）。
        VPlaceholderTextEditor(text: text, placeholder: placeholder,
                               fontSize: mono ? 12 : 13, mono: mono,
                               placeholderColor: VTheme.textDisabled,
                               contentInset: CGSize(width: 4, height: 4))
            .frame(minHeight: minHeight)
            .background(VTheme.bgApp, in: RoundedRectangle(cornerRadius: VTheme.Radius.s))
            .overlay(RoundedRectangle(cornerRadius: VTheme.Radius.s).stroke(VTheme.borderDefault))
    }

    /// 数值输入（钳区间；非法输入回落当前值——对齐 TSX number input 的 clamp 分支）。
    private func numberField(value: Int, range: ClosedRange<Int>,
                             onCommitValue: @escaping (Int) -> Void) -> some View {
        Stepper(value: Binding(
            get: { value },
            set: { onCommitValue(min(range.upperBound, max(range.lowerBound, $0))) }),
            in: range) {
            Text("\(value)")
                .font(VTheme.Typo.body.monospacedDigit())
                .frame(minWidth: 36, alignment: .leading)
        }
        .frame(width: 110, alignment: .leading)
    }

    /// 可空数值输入（空 = 删除键；对齐 batch_size 的 `e.target.value ? ... : undefined`）。
    private func optionalNumberField(value: Int?, range: ClosedRange<Int>, placeholder: String,
                                     onCommitValue: @escaping (Int?) -> Void) -> some View {
        OptionalNumberTextField(value: value, range: range, placeholder: placeholder,
                                onChange: onCommitValue)
        .frame(width: 80, alignment: .leading)
    }

    /// 路径行：输入框 + 选文件/选文件夹（NSOpenPanel 替代 Electron bridge）。
    private func pathRow(node: WorkflowNode, key: String, placeholder: String,
                         pickDir: Bool, pickFile: Bool) -> some View {
        HStack(spacing: 6) {
            TextField(placeholder, text: Binding(
                get: { node.props[key]?.string ?? "" },
                set: { vm.patchNode(id: node.id, patch: [key: .string($0)]) }))
                .vInputStyle()
            if pickFile {
                Button("选文件") {
                    if let f = Self.pickPath(directory: false) {
                        vm.patchNode(id: node.id, patch: [key: .string(f)])
                    }
                }
                .buttonStyle(.vSecondary)
                .controlSize(.small)
            }
            if pickDir {
                Button(pickFile ? "选文件夹" : "选择") {
                    if let d = Self.pickPath(directory: true) {
                        vm.patchNode(id: node.id, patch: [key: .string(d)])
                    }
                }
                .buttonStyle(.vSecondary)
                .controlSize(.small)
            }
        }
    }

    /// NSOpenPanel 选路径（Electron chooseInputFile/chooseInputDir 的原生等价物）。
    static func pickPath(directory: Bool) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = !directory
        panel.canChooseDirectories = directory
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = directory
        return panel.runModal() == .OK ? panel.url?.path : nil
    }

    /// 「可选：n1（推理节点）、n2（…）」清单（对齐 nodeIds.join('、')）。
    private var nodeIdsDescription: String {
        let parts = vm.definition.nodes.map { "\($0.id)（\($0.label ?? $0.type)）" }
        return parts.isEmpty ? "（暂无节点）" : parts.joined(separator: "、")
    }
}

/// match 字典合并补丁（保持未知键；对齐 TSX `{...(node.match || {}), key: value}`）。
private func merging(_ match: [String: JSONValue], _ patch: [String: JSONValue]) -> [String: JSONValue] {
    var out = match
    for (k, v) in patch { out[k] = v }
    return out
}

// MARK: - 工具节点 args JSON 编辑器（中途输入不强制合法，合法才落定义）

private struct ArgsJSONEditor: View {
    let node: WorkflowNode
    @ObservedObject var vm: WorkflowPanelViewModel
    @State private var text: String

    init(node: WorkflowNode, vm: WorkflowPanelViewModel) {
        self.node = node
        self.vm = vm
        // 对齐 TSX：对象 → 美化 JSON；否则原样字符串
        if let obj = node.props["args"] {
            if let data = try? JSONEncoder().encode(obj),
               let pretty = try? JSONSerialization.jsonObject(with: data),
               let prettyData = try? JSONSerialization.data(withJSONObject: pretty, options: [.prettyPrinted]),
               let s = String(data: prettyData, encoding: .utf8) {
                _text = State(initialValue: s)
            } else {
                _text = State(initialValue: "{}")
            }
        } else {
            _text = State(initialValue: "{}")
        }
    }

    var body: some View {
        TextEditor(text: $text)
            .font(.system(size: 12, design: .monospaced))
            .frame(minHeight: 70)
            .scrollContentBackground(.hidden)
            .padding(4)
            .background(VTheme.bgApp, in: RoundedRectangle(cornerRadius: VTheme.Radius.s))
            .overlay(RoundedRectangle(cornerRadius: VTheme.Radius.s).stroke(VTheme.borderDefault))
            .onChange(of: text) { _, newValue in
                // 对齐 TSX：JSON.parse 成功才 patchNode；失败静默（输入中途不打扰）
                guard let data = newValue.data(using: .utf8),
                      let parsed = try? JSONDecoder().decode(JSONValue.self, from: data) else { return }
                vm.patchNode(id: node.id, patch: ["args": parsed])
            }
    }
}

// MARK: - 可空数值输入框（文本态，空串 = nil；失焦/回车钳区间）

private struct OptionalNumberTextField: View {
    let value: Int?
    let range: ClosedRange<Int>
    let placeholder: String
    let onChange: (Int?) -> Void
    @State private var text: String

    init(value: Int?, range: ClosedRange<Int>, placeholder: String, onChange: @escaping (Int?) -> Void) {
        self.value = value
        self.range = range
        self.placeholder = placeholder
        self.onChange = onChange
        _text = State(initialValue: value.map(String.init) ?? "")
    }

    var body: some View {
        TextField(placeholder, text: $text)
            .vInputStyle()
            .onChange(of: text) { _, newValue in
                let trimmed = newValue.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty {
                    onChange(nil)      // 对齐 TSX：留空 → undefined（删键）
                } else if let n = Int(trimmed) {
                    onChange(min(range.upperBound, max(range.lowerBound, n)))
                }
            }
            .onChange(of: value) { _, newValue in
                // 外部值变化（如切节点复用）回填文本态
                let s = newValue.map(String.init) ?? ""
                if s != text { text = s }
            }
    }
}
