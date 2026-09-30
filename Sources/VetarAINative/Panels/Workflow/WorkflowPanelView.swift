//
//  WorkflowPanelView.swift
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

//  流程中心主面板（对标 subagent/renderer/src/panels/WorkflowPanel.tsx，357 行）：
//    布局（图2 两板块单栏化后）：左列工作流列表迁去流程中心侧栏手风琴
//          （WorkflowSidebarView），内容区 = 中列 工具栏+运行参数+画布+JSON/审批/
//          事件流+运行记录（弹性）| 右侧节点配置 320pt（选中节点时，WorkflowEditorView）
//    V3 布局正修（纠正 U1 过度刚性化）：中列 = 唯一弹性列（tsx:278 flex:1 + minWidth:0），
//          frame(minWidth:0, maxWidth:.infinity) + 最低 layoutPriority + clipped——
//          点选节点插入 320 编辑器时只压画布，rail/侧栏/编辑器完整在窗内；
//          工具栏名称框去固定 180 改弹性（80~180）、运行参数标签去 fixedSize 可截断、
//          工具栏整行允许 clipped（不为中列贡献最小宽度）
//    运行：POST /api/workflows/{id}/run（SSE）实时刷新节点状态与事件流；
//          审批节点弹审批卡片（通过/驳回）；停止 = 先服务端 stop 再断本地流
//    0.2.1（TS-119）只读 JSON 查看：完整定义结构，供核对/复制
//    运行记录查看（任务要求；端点现状存在）：列表 + 展开详情（节点事件表）
//
//  ViewModel 走 WorkflowCenterState 共享单例（侧栏手风琴与内容区同源；
//  attach/detach 计数生命周期替代原 Box 延迟构建 + start/stop）。
//

import SwiftUI

public struct WorkflowPanelView: View {
    @EnvironmentObject private var center: WorkflowCenterState

    public init() {}

    public var body: some View {
        if let vm = center.workflowVM {
            WorkflowPanelBody(vm: vm)
        } else {
            VLoadingView("流程中心初始化…")
        }
    }
}

private struct WorkflowPanelBody: View {
    @ObservedObject var vm: WorkflowPanelViewModel

    var body: some View {
        HStack(spacing: 0) {
            centerColumn
                // V3：中列 = 唯一弹性列（对齐 WorkflowPanel.tsx:278 `flex:1, minWidth:0`）——
                // 可压到近 0 而不推挤固定列；内部超宽内容裁切而非越界绘制，
                // 修复 U1 全列 fixedSize 后总宽超窗时 SwiftUI 居中溢出、左右同裁的症状
                .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(-1)
                .clipped()
            if vm.selected != nil, vm.selectedNodeId != nil {
                Divider()
                WorkflowEditorView(vm: vm)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(VTheme.bgApp)
        // 双挂载点计数生命周期：侧栏手风琴列表与本面板任一存活则 VM 不停
        .onAppear { vm.attach() }
        .onDisappear { vm.detach() }
    }

    // MARK: - 中列：画布 + 运行监控

    @ViewBuilder
    private var centerColumn: some View {
        if vm.selected == nil {
            VStack(spacing: 8) {
                Image(systemName: "square.stack.3d.up")
                    .font(.system(size: 32))
                    .foregroundStyle(VTheme.textTertiary)
                Text("流程中心：新建或选择一个工作流开始编排")
                    .font(.system(size: 14))
                    .foregroundStyle(VTheme.textTertiary)
                Text("节点类型：推理 / 工具 / 条件分支 / 并行 / 循环 / 人工审批")
                    .font(VTheme.Typo.caption)
                    .foregroundStyle(VTheme.textTertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                toolbar
                if !vm.validateMsg.isEmpty {
                    VCallout(.error, vm.validateMsg)
                        .padding(.horizontal, 12)
                        .padding(.top, 6)
                }
                paramsRow
                WorkflowCanvasView(
                    definition: vm.definition,
                    selectedNodeId: vm.selectedNodeId,
                    nodeStatus: vm.nodeStatus,
                    onSelectNode: { vm.selectedNodeId = $0 })
                if vm.showJson { jsonView }
                if let approval = vm.approval { approvalCard(approval) }
                eventStream
                Divider()
                runsSection
            }
        }
    }

    // MARK: 工具栏

    private var toolbar: some View {
        HStack(spacing: 8) {
            TextField("", text: $vm.name)
                .vInputStyle()
                // V3：去固定 180 改弹性（原版 width:180 处在 flex 行内可缩）——
                // 窗口挤压时收缩至 80，把行宽让给按钮；工具栏不为中列贡献最小宽度
                .frame(minWidth: 80, idealWidth: 180, maxWidth: 180, alignment: .leading)
                .accessibilityIdentifier("workflowName")
            TextField("描述（可选）", text: $vm.desc)
                .vInputStyle()
            Button {
                Task { await vm.saveWorkflow() }
            } label: {
                Label("保存\(vm.dirty ? " *" : "")", systemImage: "checkmark")
                    .font(VTheme.Typo.caption)
            }
            .buttonStyle(.vPrimary)
            .controlSize(.small)
            .disabled(!vm.dirty && vm.validateMsg.isEmpty)
            .accessibilityIdentifier("workflowSave")

            Button {
                vm.showJson.toggle()
            } label: {
                Label(vm.showJson ? "收起 JSON" : "查看 JSON", systemImage: "doc.text")
                    .font(VTheme.Typo.caption)
            }
            .buttonStyle(.vSecondary)
            .controlSize(.small)
            .accessibilityIdentifier("workflowToggleJson")

            if !vm.running {
                Button { vm.runWorkflow() } label: {
                    Label("运行", systemImage: "play")
                        .font(VTheme.Typo.caption)
                }
                .buttonStyle(.vPrimary)
                .controlSize(.small)
                .accessibilityIdentifier("workflowRun")
            } else {
                Button { vm.stopRunServer() } label: {
                    Label("停止", systemImage: "stop")
                        .font(VTheme.Typo.caption)
                }
                .buttonStyle(.vDanger)
                .controlSize(.small)
                .accessibilityIdentifier("workflowStop")
            }

            if vm.selected?.builtIn == false {
                Button { vm.deleteWorkflow() } label: {
                    Image(systemName: "trash")
                        .font(VTheme.Typo.caption)
                }
                .buttonStyle(.vDanger)
                .controlSize(.small)
                .help("删除工作流")
                .accessibilityIdentifier("workflowDelete")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(VTheme.bgCard)
        .overlay(alignment: .bottom) { Divider() }
        // V3：整行允许裁切——按钮保持固有尺寸，行内容超宽时裁掉而非顶宽中列
        .clipped()
    }

    // MARK: 运行参数行

    private var paramsRow: some View {
        HStack(spacing: 6) {
            Text("运行参数（JSON，引用 {{params.名称}}）：")
                .font(VTheme.Typo.micro)
                .foregroundStyle(VTheme.textTertiary)
                // V3：去 fixedSize——极窄时标签截断而非把行宽顶出中列
                // （原版 WorkflowPanel.tsx:315-316：标签 flexShrink:0、输入框 flex:1 吸收压缩）
                .lineLimit(1)
                .truncationMode(.tail)
            TextField("{\"images\": [], \"dir\": \"...\"}", text: $vm.paramsText)
                .vInputStyle()
                .font(VTheme.Typo.caption)
                .accessibilityIdentifier("workflowRunParams")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(VTheme.bgCard)
        .overlay(alignment: .bottom) { Divider() }
        .clipped()
    }

    // MARK: 只读 JSON 查看（0.2.1 TS-119）

    private var jsonView: some View {
        ScrollView {
            Text(definitionJSONText)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(VTheme.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        }
        .frame(maxHeight: 220)
        .background(VTheme.bgApp)
        .overlay(alignment: .top) { Divider() }
        .accessibilityIdentifier("workflowJsonView")
    }

    /// JSON.stringify(definition, null, 2) 等价物。
    private var definitionJSONText: String {
        guard let data = try? JSONEncoder().encode(vm.definition),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted]),
              let s = String(data: pretty, encoding: .utf8) else { return "{}" }
        return s
    }

    // MARK: 审批卡片（对齐 callout warn + 通过/驳回）

    private func approvalCard(_ approval: WorkflowPanelViewModel.ApprovalCard) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(VTheme.warnText)
            Text("\(approval.label)：\(approval.message)")
                .font(VTheme.Typo.caption)
                .foregroundStyle(VTheme.warnText)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("通过") { vm.respondApproval(approved: true) }
                .buttonStyle(.vPrimary)
                .controlSize(.small)
                .accessibilityIdentifier("workflowApprove")
            Button("驳回") { vm.respondApproval(approved: false) }
                .buttonStyle(.vDanger)
                .controlSize(.small)
                .accessibilityIdentifier("workflowReject")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(VTheme.warnBg, in: RoundedRectangle(cornerRadius: VTheme.Radius.s))
        .overlay(RoundedRectangle(cornerRadius: VTheme.Radius.s).stroke(VTheme.warnBorder))
        .padding(8)
        // DBG-160：容器不挂 id（内有 workflowApprove/workflowReject 叶子 id）
    }

    // MARK: 事件流（mono 日志，上限高 150，对齐 TSX）

    private var eventStream: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if vm.events.isEmpty {
                        Text("运行事件将显示在这里。")
                            .foregroundStyle(VTheme.textTertiary)
                    }
                    ForEach(vm.events) { ev in
                        Text(ev.lineText)
                            .foregroundStyle(ev.isError ? VTheme.dangerText : VTheme.textSecondary)
                            .lineSpacing(3)
                            .id(ev.id)
                    }
                    if vm.running {
                        HStack(spacing: 4) {
                            ProgressView().controlSize(.mini)
                            Text("运行中…")
                        }
                        .foregroundStyle(VTheme.accentText)
                        .id("workflowRunningFooter")
                    }
                }
                .font(.system(size: 11, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            .frame(maxHeight: 150)
            .background(VTheme.bgCard)
            .overlay(alignment: .top) { Divider() }
            .onChange(of: vm.events.count) { _, _ in
                if let last = vm.events.last?.id {
                    proxy.scrollTo(last, anchor: .bottom)
                }
            }
        }
        .accessibilityIdentifier("workflowEventStream")
    }

    // MARK: - 运行记录（list + 展开详情；现状端点 GET /workflow-runs[/id]）

    private var runsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text("运行记录")
                    .font(VTheme.Typo.caption.weight(.semibold))
                    .foregroundStyle(VTheme.textSecondary)
                if vm.runsLoading { ProgressView().controlSize(.mini) }
                Spacer()
                Button { Task { await vm.loadRuns() } } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11))
                }
                .buttonStyle(.vGhost)
                .controlSize(.small)
                .help("刷新运行记录")
                .accessibilityIdentifier("workflowRunsRefresh")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            if vm.runs.isEmpty && !vm.runsLoading {
                Text("暂无运行记录。")
                    .font(VTheme.Typo.micro)
                    .foregroundStyle(VTheme.textTertiary)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }
            ForEach(vm.runs) { run in
                runRow(run)
                if vm.expandedRunId == run.id {
                    runDetailView(run.id)
                }
            }
        }
        .frame(maxHeight: 220)
        .background(VTheme.bgCard)
        // DBG-160：容器不挂 id（内有 workflowRunsRefresh/runRow.*/runDetail.* 叶子 id）
    }

    private func runRow(_ run: WorkflowRunRecord) -> some View {
        Button { vm.toggleRunDetail(run.id) } label: {
            HStack(spacing: 8) {
                runStatusBadge(run.status)
                Text(run.createdAt ?? "")
                    .font(VTheme.Typo.micro)
                    .foregroundStyle(VTheme.textTertiary)
                if let node = run.currentNode, run.isActive {
                    Text("· \(node)")
                        .font(VTheme.Typo.micro)
                        .foregroundStyle(VTheme.textTertiary)
                }
                Spacer()
                if let error = run.error, !error.isEmpty {
                    Text(String(error.prefix(60)))
                        .font(VTheme.Typo.micro)
                        .foregroundStyle(VTheme.dangerText)
                        .lineLimit(1)
                } else if let result = run.result, !result.isEmpty {
                    Text(String(result.prefix(60)))
                        .font(VTheme.Typo.micro)
                        .foregroundStyle(VTheme.textSecondary)
                        .lineLimit(1)
                }
                Image(systemName: vm.expandedRunId == run.id ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9))
                    .foregroundStyle(VTheme.textTertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("workflowRunRow.\(run.id)")
    }

    /// 状态徽标（running 蓝 / awaiting_approval 黄 / done 绿 / failed 红 / stopped 灰）。
    private func runStatusBadge(_ status: String) -> some View {
        let (label, fg, bg): (String, Color, Color) = {
            switch status {
            case "running": return ("进行中", VTheme.accentTextDeep, VTheme.accentBg)
            case "awaiting_approval": return ("待审批", VTheme.warnText, VTheme.warnBg)
            case "done": return ("完成", VTheme.okText, VTheme.okBg)
            case "failed": return ("失败", VTheme.dangerText, VTheme.dangerBg)
            case "stopped": return ("已停止", VTheme.textSecondary, VTheme.bgHover)
            default: return (status, VTheme.textSecondary, VTheme.bgHover)
            }
        }()
        return Text(label)
            .font(VTheme.Typo.micro)
            .foregroundStyle(fg)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(bg, in: Capsule())
    }

    /// 运行详情：结果/错误 + 节点事件表（node_events 按 id 升序，后端已排好）。
    private func runDetailView(_ runId: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if vm.runDetailLoading {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("加载详情…")
                }
                .font(VTheme.Typo.micro)
                .foregroundStyle(VTheme.textTertiary)
            } else if let detail = vm.runDetail {
                if let result = detail.result, !result.isEmpty {
                    Text("结果：\(String(result.prefix(200)))")
                        .font(VTheme.Typo.micro)
                        .foregroundStyle(VTheme.okText)
                        .lineLimit(3)
                }
                if let error = detail.error, !error.isEmpty {
                    Text("错误：\(error)")
                        .font(VTheme.Typo.micro)
                        .foregroundStyle(VTheme.dangerText)
                        .lineLimit(3)
                }
                ForEach(detail.nodeEvents) { ev in
                    HStack(spacing: 6) {
                        Image(systemName: ev.status == "done" ? "checkmark.circle" :
                                ev.status == "error" ? "xmark.circle" : "arrow.right.circle")
                            .font(.system(size: 10))
                            .foregroundStyle(ev.status == "done" ? VTheme.okText :
                                                ev.status == "error" ? VTheme.dangerText : VTheme.accentText)
                        Text("\(ev.nodeId)（\(ev.nodeType)）")
                            .foregroundStyle(VTheme.textSecondary)
                        if let ms = ev.durationMs {
                            Text("\(ms)ms")
                        }
                        if ev.retryCount > 0 {
                            Text("重试×\(ev.retryCount)")
                        }
                        if let model = ev.modelUsed, !model.isEmpty {
                            Text(model.split(separator: ":").first.map(String.init) ?? model)
                        }
                        Spacer()
                    }
                    .font(VTheme.Typo.micro)
                    if !ev.outputSummary.isEmpty {
                        Text(String(ev.outputSummary.prefix(120)))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(VTheme.textTertiary)
                            .lineLimit(2)
                            .padding(.leading, 16)
                    }
                    if let err = ev.error, !err.isEmpty {
                        Text(err)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(VTheme.dangerText)
                            .lineLimit(2)
                            .padding(.leading, 16)
                    }
                }
                if detail.nodeEvents.isEmpty {
                    Text("（无节点事件）")
                        .font(VTheme.Typo.micro)
                        .foregroundStyle(VTheme.textTertiary)
                }
            } else {
                Text("详情加载失败或已不存在。")
                    .font(VTheme.Typo.micro)
                    .foregroundStyle(VTheme.textTertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(VTheme.bgApp)
        .accessibilityIdentifier("workflowRunDetail.\(runId)")
    }
}
