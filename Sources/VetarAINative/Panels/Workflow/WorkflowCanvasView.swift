//
//  WorkflowCanvasView.swift
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

//  工作流可视化画布（对标 subagent/renderer/src/panels/WorkflowCanvas.tsx，132 行 SVG 版）：
//    · 自动布局（WorkflowLayout，拓扑分层）渲染节点卡片与连线；条件边标注分支名
//    · 点击节点 → onSelectNode(id) 打开侧边配置表单
//    · 运行时态：nodeStatus 标记节点 进行中(蓝)/成功(绿)/失败(红) 描边环
//    · 原生增强：SwiftUI Canvas 自绘 + 捏合缩放 + 拖拽平移 + 双击复位
//      （现状 SVG 无缩放平移；任务要求「从简但要有」）
//
//  坐标口径与 TS 版逐像素一致（WorkflowLayout 常量）；命中测试为纯静态函数（单测覆盖）。
//

import SwiftUI

public struct WorkflowCanvasView: View {
    let definition: WorkflowDefinition
    let selectedNodeId: String?
    let nodeStatus: [String: WorkflowNodeStatus]
    var onSelectNode: ((String) -> Void)?

    @State private var zoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @GestureState private var pinchScale: CGFloat = 1
    @GestureState private var dragTranslation: CGSize = .zero

    public init(definition: WorkflowDefinition,
                selectedNodeId: String? = nil,
                nodeStatus: [String: WorkflowNodeStatus] = [:],
                onSelectNode: ((String) -> Void)? = nil) {
        self.definition = definition
        self.selectedNodeId = selectedNodeId
        self.nodeStatus = nodeStatus
        self.onSelectNode = onSelectNode
    }

    // MARK: - 变换（缩放 0.4x~2.5x，平移任意；双击复位）

    private var effectiveZoom: CGFloat {
        min(2.5, max(0.4, zoom * pinchScale))
    }
    private var effectivePan: CGSize {
        CGSize(width: pan.width + dragTranslation.width,
               height: pan.height + dragTranslation.height)
    }

    /// 视口坐标 → 画布（布局）坐标。命中测试与绘制共用同一变换，绝不打架。
    static func toCanvasPoint(_ viewPoint: CGPoint, zoom: CGFloat, pan: CGSize) -> CGPoint {
        CGPoint(x: (viewPoint.x - pan.width) / zoom,
                y: (viewPoint.y - pan.height) / zoom)
    }

    /// 命中测试：返回包含该画布坐标的节点 id（后画先中 = 数组倒序，对齐 DOM 上层优先）。
    static func hitTest(canvasPoint: CGPoint, positions: [String: CGPoint]) -> String? {
        for (id, p) in positions.sorted(by: { $0.key < $1.key }).reversed() {
            let rect = CGRect(x: p.x, y: p.y, width: WorkflowLayout.nodeW, height: WorkflowLayout.nodeH)
            if rect.contains(canvasPoint) { return id }
        }
        return nil
    }

    /// 节点状态描边色（对齐 statusRing：running→accent / done→ok / error→danger）。
    static func statusRing(_ status: WorkflowNodeStatus?) -> Color? {
        switch status {
        case .running: return VTheme.accent
        case .done: return VTheme.ok
        case .error: return VTheme.danger
        case .pending, nil: return nil
        }
    }

    public var body: some View {
        let positions = WorkflowLayout.layout(definition)
        Canvas { ctx, _ in
            ctx.translateBy(x: effectivePan.width, y: effectivePan.height)
            ctx.scaleBy(x: effectiveZoom, y: effectiveZoom)
            drawEdges(ctx: &ctx, positions: positions)
            drawNodes(ctx: &ctx, positions: positions)
        }
        .background(VTheme.bgApp)
        .contentShape(Rectangle())
        .gesture(panGesture)
        .gesture(zoomGesture)
        .simultaneousGesture(tapGesture(positions: positions))
        .overlay(alignment: .bottomTrailing) { zoomControls }
        // DBG-160：容器不挂 id（内有 workflowCanvasZoomControls 叶子 id）
    }

    // MARK: - 手势

    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 4)
            .updating($dragTranslation) { value, state, _ in state = value.translation }
            .onEnded { value in
                pan.width += value.translation.width
                pan.height += value.translation.height
            }
    }

    private var zoomGesture: some Gesture {
        MagnificationGesture()
            .updating($pinchScale) { value, state, _ in state = value }
            .onEnded { value in
                zoom = min(2.5, max(0.4, zoom * value))
            }
    }

    private func tapGesture(positions: [String: CGPoint]) -> some Gesture {
        SpatialTapGesture(count: 1)
            .onEnded { value in
                let p = Self.toCanvasPoint(value.location, zoom: zoom, pan: pan)
                if let id = Self.hitTest(canvasPoint: p, positions: positions) {
                    onSelectNode?(id)
                }
            }
    }

    private func resetView() {
        withAnimation(.easeOut(duration: 0.15)) {
            zoom = 1
            pan = .zero
        }
    }

    private var zoomControls: some View {
        HStack(spacing: 4) {
            Button { zoom = min(2.5, zoom + 0.2) } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            Button { zoom = max(0.4, zoom - 0.2) } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            Button { resetView() } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
            }
        }
        .font(.system(size: 11))
        .buttonStyle(.vSecondary)
        .controlSize(.mini)
        .padding(6)
        .background(VTheme.bgCard.opacity(0.85), in: RoundedRectangle(cornerRadius: VTheme.Radius.s))
        .padding(8)
        .accessibilityIdentifier("workflowCanvasZoomControls")
    }

    // MARK: - 绘制：连线（对齐 SVG path 口径：近垂直直线，否则三次贝塞尔 + 箭头 + when 标签）

    private func drawEdges(ctx: inout GraphicsContext, positions: [String: CGPoint]) {
        for e in definition.edges {
            guard let p1 = positions[e.from], let p2 = positions[e.to] else { continue }
            let x1 = p1.x + WorkflowLayout.nodeW / 2
            let y1 = p1.y + WorkflowLayout.nodeH
            let x2 = p2.x + WorkflowLayout.nodeW / 2
            let y2 = p2.y
            let midY = (y1 + y2) / 2
            let end = CGPoint(x: x2, y: y2 - 6)

            var path = Path()
            path.move(to: CGPoint(x: x1, y: y1))
            if abs(x1 - x2) < 4 {
                path.addLine(to: end)
            } else {
                path.addCurve(to: end,
                              control1: CGPoint(x: x1, y: midY),
                              control2: CGPoint(x: x2, y: midY))
            }
            ctx.stroke(path, with: .color(VTheme.borderStrong), lineWidth: 1.5)
            drawArrowhead(ctx: &ctx, tip: end, from: abs(x1 - x2) < 4
                          ? CGPoint(x: x1, y: y1) : CGPoint(x: x2, y: midY))

            if let when = e.when, !when.isEmpty {
                ctx.draw(Text(when).font(.system(size: 10)).foregroundStyle(VTheme.textSecondary),
                         at: CGPoint(x: (x1 + x2) / 2 + 8, y: midY))
            }
        }
    }

    /// 箭头三角（对齐 SVG marker wf-arrow：9×9，尖端朝行进方向）。
    private func drawArrowhead(ctx: inout GraphicsContext, tip: CGPoint, from: CGPoint) {
        let dx = tip.x - from.x
        let dy = tip.y - from.y
        let len = max(0.001, hypot(dx, dy))
        let ux = dx / len, uy = dy / len        // 行进方向单位向量
        let px = -uy, py = ux                    // 法向
        let size: CGFloat = 9
        var tri = Path()
        tri.move(to: tip)
        tri.addLine(to: CGPoint(x: tip.x - ux * size + px * size / 2,
                                y: tip.y - uy * size + py * size / 2))
        tri.addLine(to: CGPoint(x: tip.x - ux * size - px * size / 2,
                                y: tip.y - uy * size - py * size / 2))
        tri.closeSubpath()
        ctx.fill(tri, with: .color(VTheme.borderStrong))
    }

    // MARK: - 绘制：节点卡片（圆角矩形 + 左侧分类色条 + 标题/副标题两行）

    private func drawNodes(ctx: inout GraphicsContext, positions: [String: CGPoint]) {
        for n in definition.nodes {
            guard let p = positions[n.id] else { continue }
            let meta = WorkflowNodeTypes.meta(for: n.type)
            let rect = CGRect(x: p.x, y: p.y, width: WorkflowLayout.nodeW, height: WorkflowLayout.nodeH)
            let sel = selectedNodeId == n.id
            let ring = Self.statusRing(nodeStatus[n.id])

            // 卡体
            ctx.fill(Path(roundedRect: rect, cornerRadius: VTheme.Radius.m), with: .color(VTheme.bgCard))
            ctx.stroke(Path(roundedRect: rect, cornerRadius: VTheme.Radius.m),
                       with: .color(ring ?? (sel ? VTheme.accent : VTheme.borderDefault)),
                       lineWidth: (sel || ring != nil) ? 2 : 1)
            // 左侧分类色条（宽 4，圆角 2）
            let bar = CGRect(x: p.x, y: p.y, width: 4, height: WorkflowLayout.nodeH)
            ctx.fill(Path(roundedRect: bar, cornerRadius: 2), with: .color(meta.color))
            // 标题（label 缺省用类型中文名；截 14 字，对齐 TSX slice(0, 14)）
            let title = String((n.label ?? meta.label).prefix(14))
            ctx.draw(Text(title).font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(VTheme.textPrimary),
                     at: CGPoint(x: p.x + 14, y: p.y + 15), anchor: .leading)
            // 副标题：类型名 + 模型前缀（对齐 `meta.label + (model ? ' · ' + model.split(':')[0] : '')`）
            var subtitle = meta.label
            if let model = n.props["model"]?.string, !model.isEmpty {
                subtitle += " · \(model.split(separator: ":").first.map(String.init) ?? model)"
            }
            ctx.draw(Text(subtitle).font(.system(size: 10.5))
                        .foregroundStyle(VTheme.textTertiary),
                     at: CGPoint(x: p.x + 14, y: p.y + 33), anchor: .leading)
        }
    }
}
