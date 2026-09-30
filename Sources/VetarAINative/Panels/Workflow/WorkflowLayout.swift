//
//  WorkflowLayout.swift
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

//  工作流画布自动布局（纯函数，可单测）——逐行移植
//  subagent/renderer/src/lib/workflowLayout.ts（0.2.1 TS-119 + 0.2.4 W3 破环）：
//    · 拓扑分层（最长路径松弛），同层水平居中排列，层间纵向排列
//    · parallel.branches / loop.branch 视为隐式边参与分层（不画连线）
//    · 破环：DFS 三色标记检出回边（目标节点已在当前路径上的边）→ 剪除后重验，
//      避免条件节点放进循环体时"最长路径"被环反复推深层（超长连线）
//    · 孤立节点（start 不可达）垫底排布，画布上仍可见
//  常量与坐标口径与 TS 完全一致（NODE_W=176, NODE_H=52, H_GAP=56, V_GAP=68, PAD=24），
//  保证画布观感与现状逐像素对齐。
//

import Foundation
import CoreGraphics

public enum WorkflowLayout {
    public static let nodeW: CGFloat = 176
    public static let nodeH: CGFloat = 52
    public static let hGap: CGFloat = 56
    public static let vGap: CGFloat = 68
    public static let pad: CGFloat = 24

    /// 计算每个节点的左上角坐标（键 = 节点 id）。
    public static func layout(_ definition: WorkflowDefinition) -> [String: CGPoint] {
        let nodes = definition.nodes
        let edges = definition.edges
        let ids = Set(nodes.map(\.id))

        // ── 邻接表（含 parallel/loop 隐式分支边）──
        var adj: [String: [String]] = [:]
        for n in nodes { adj[n.id] = [] }
        for e in edges where adj[e.from] != nil && ids.contains(e.to) {
            adj[e.from, default: []].append(e.to)
        }
        for n in nodes {
            if n.type == "parallel",
               case .array(let branches)? = n.props["branches"] {
                for b in branches {
                    if let s = b.string, ids.contains(s) { adj[n.id, default: []].append(s) }
                }
            }
            // loop.branch：TS 布局只认整串单 id（"ocr,save" 顺序链是 0.2.4 校验侧口径，
            // 布局库未跟进——逐字保留现状：整串命中才算隐式边）。
            if n.type == "loop", let branch = n.props["branch"]?.string, ids.contains(branch) {
                adj[n.id, default: []].append(branch)
            }
        }

        // ── 破环（0.2.4 W3）：反复 DFS 检环并剪除环上回边，直到无环 ──
        removeBackEdges(nodes: nodes, adj: &adj)

        // ── 分层：最长路径松弛（环已剪除，必然收敛）──
        var layer: [String: Int] = [:]
        let start = nodes.first { $0.type == "start" }
        if let start { layer[start.id] = 0 }
        if start == nil && !nodes.isEmpty {
            // 没有 start 时从入度为 0 的节点起层（兜底）
            let hasIn = Set(edges.map(\.to))
            for n in nodes where !hasIn.contains(n.id) {
                if layer[n.id] == nil { layer[n.id] = 0 }
            }
            if layer.isEmpty { layer[nodes[0].id] = 0 }
        }
        for _ in 0...(nodes.count) {
            var changed = false
            for (from, tos) in adj {
                guard let lf = layer[from] else { continue }
                for t in tos {
                    if layer[t] == nil || layer[t]! < lf + 1 {
                        layer[t] = lf + 1
                        changed = true
                    }
                }
            }
            if !changed { break }
        }
        // 孤立节点垫底（不丢失，画布仍可见）
        let maxLayer = layer.values.max() ?? 0
        var extra = 0
        for n in nodes where layer[n.id] == nil {
            layer[n.id] = maxLayer + 1 + extra
            extra += 1
        }

        // ── 分组定位（同层水平居中排列）──
        var byLayer: [Int: [String]] = [:]
        for n in nodes {
            guard let l = layer[n.id] else { continue }
            byLayer[l, default: []].append(n.id)
        }
        let maxCount = max(1, byLayer.values.map(\.count).max() ?? 1)
        let totalW = CGFloat(maxCount) * nodeW + CGFloat(maxCount - 1) * hGap

        var pos: [String: CGPoint] = [:]
        for (l, idsInLayer) in byLayer {
            let width = CGFloat(idsInLayer.count) * nodeW + CGFloat(idsInLayer.count - 1) * hGap
            let offsetX = (totalW - width) / 2
            for (i, id) in idsInLayer.enumerated() {
                pos[id] = CGPoint(
                    x: pad + offsetX + CGFloat(i) * (nodeW + hGap),
                    y: pad + CGFloat(l) * (nodeH + vGap))
            }
        }
        return pos
    }

    /// 画布总尺寸（含右/下 padding；TS layoutSize 同口径）。
    public static func canvasSize(_ positions: [String: CGPoint]) -> CGSize {
        var w: CGFloat = 0
        var h: CGFloat = 0
        for p in positions.values {
            w = max(w, p.x + nodeW)
            h = max(h, p.y + nodeH)
        }
        return CGSize(width: w + pad, height: h + pad)
    }

    /// DFS 三色标记检环（0=白 1=灰=在当前路径 2=黑）；命中回边（from→to，to 灰色）
    /// 即从邻接表剪除，重验直到无环。guard 上限 = 节点数×2（对齐 TS 实现）。
    static func removeBackEdges(nodes: [WorkflowNode], adj: inout [String: [String]]) {
        for _ in 0..<(nodes.count * 2) {
            var color: [String: Int] = [:]
            var backFrom = ""
            var backTo = ""
            var found = false

            func dfs(_ u: String) -> Bool {
                color[u] = 1
                for v in adj[u] ?? [] {
                    if color[v] == 1 { backFrom = u; backTo = v; return true }   // 命中回边
                    if color[v] == nil, dfs(v) { return true }
                }
                color[u] = 2
                return false
            }
            for n in nodes where color[n.id] == nil {
                if dfs(n.id) { found = true; break }
            }
            guard found else { return }   // 无环
            adj[backFrom] = (adj[backFrom] ?? []).filter { $0 != backTo }
        }
    }
}
