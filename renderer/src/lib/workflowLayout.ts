/**
 * 0.2.1（TS-119）：工作流画布自动布局（纯函数，可单测）。
 *
 * 算法：拓扑分层（最长路径）——同层节点水平排列（条件分支/并行分支自然并排），
 * 层间纵向排列。parallel.branches / loop.branch 视为隐式边参与分层。
 * 无环假设下 O(V·E)；带环时限制迭代轮数兜底。
 */

export const NODE_W = 176;
export const NODE_H = 52;
export const H_GAP = 56;
export const V_GAP = 68;
export const PAD = 24;

export interface WfNode {
  id: string;
  type: string;
  label?: string;
  [k: string]: any;
}
export interface WfEdge {
  from: string;
  to: string;
  when?: string;
}
export interface WfDefinition {
  nodes: WfNode[];
  edges: WfEdge[];
  params?: Record<string, any>;
}

/** 计算每个节点的左上角坐标。未连通节点排在最底部（不丢失）。 */
export function layoutWorkflow(definition: WfDefinition): Record<string, { x: number; y: number }> {
  const nodes = Array.isArray(definition?.nodes) ? definition.nodes : [];
  const edges = Array.isArray(definition?.edges) ? definition.edges : [];
  const ids = new Set(nodes.map(n => n.id));

  // 邻接表（含 parallel/loop 的隐式分支边）
  const adj: Record<string, string[]> = {};
  nodes.forEach(n => { adj[n.id] = []; });
  edges.forEach(e => {
    if (e && adj[e.from] !== undefined && ids.has(e.to)) adj[e.from].push(e.to);
  });
  nodes.forEach(n => {
    if (n.type === 'parallel' && Array.isArray(n.branches)) {
      n.branches.forEach((b: string) => { if (ids.has(b)) adj[n.id].push(b); });
    }
    if (n.type === 'loop' && typeof n.branch === 'string' && ids.has(n.branch)) {
      adj[n.id].push(n.branch);
    }
  });

  // 0.2.4（W3）：破环——检测并移除回边（指向已分层祖先的边）。
  // 背景：条件节点放进循环体、或用户连出回路时，"最长路径松弛"会被环
  // 反复推深层，节点被压到极深层 → 画布出现跨越巨大空隙的超长连线。
  // 做法：先按 start 可达性做拓扑着色，凡是"目标节点已在当前路径上"的回边
  // 不参与分层（从邻接表中移除）。用 Kahn 入度法检测环更稳妥。
  const indeg: Record<string, number> = {};
  ids.forEach(id => { indeg[id] = 0; });
  Object.values(adj).forEach(tos => tos.forEach(t => { indeg[t] = (indeg[t] || 0) + 1; }));
  // Kahn：若全部出队失败（有环），逐轮剪回边——找仍有余入度的节点中，
  // 其"仍在余图中入度>0 的入邻居"里层数最小者作为回边剪除。
  // 简化实现：反复用 DFS 检测环并剪除环上最后一条边，直到无环。
  const removeBackEdges = () => {
    for (let guard = 0; guard < nodes.length * 2; guard++) {
      const color: Record<string, number> = {}; // 0=白 1=灰 2=黑
      let backFrom = '', backTo = '';
      const dfs = (u: string, stack: string[]): boolean => {
        color[u] = 1;
        for (const v of (adj[u] || [])) {
          if (color[v] === 1) { backFrom = u; backTo = v; return true; } // 命中回边
          if (!color[v] && dfs(v, [...stack, u])) return true;
        }
        color[u] = 2;
        return false;
      };
      const roots = nodes.map(n => n.id);
      let found = false;
      for (const r of roots) {
        if (!color[r] && dfs(r, [])) { found = true; break; }
      }
      if (!found) return; // 无环
      // 剪除回边 backFrom -> backTo
      adj[backFrom] = (adj[backFrom] || []).filter(t => t !== backTo);
    }
  };
  removeBackEdges();

  // 分层：最长路径松弛（环已剪除，必然收敛）
  const layer: Record<string, number> = {};
  const start = nodes.find(n => n.type === 'start');
  if (start) layer[start.id] = 0;
  // 没有 start 时从入度为 0 的节点起层（兜底）
  if (!start && nodes.length) {
    const hasIn = new Set(edges.map(e => e.to));
    nodes.forEach(n => { if (!hasIn.has(n.id)) layer[n.id] = layer[n.id] ?? 0; });
    if (Object.keys(layer).length === 0) layer[nodes[0].id] = 0;
  }
  for (let round = 0; round < nodes.length + 1; round++) {
    let changed = false;
    for (const [from, tos] of Object.entries(adj)) {
      if (layer[from] === undefined) continue;
      for (const t of tos) {
        if (layer[t] === undefined || layer[t] < layer[from] + 1) {
          layer[t] = layer[from] + 1;
          changed = true;
        }
      }
    }
    if (!changed) break;
  }
  // 孤立节点（无 start 可达）：垫底排布，画布上仍可见
  const maxLayer = Math.max(0, ...Object.values(layer));
  let extra = 0;
  nodes.forEach(n => {
    if (layer[n.id] === undefined) { layer[n.id] = maxLayer + 1 + extra; extra++; }
  });

  // 分组定位（同层水平居中排列）
  const byLayer: Record<number, string[]> = {};
  nodes.forEach(n => { (byLayer[layer[n.id]] ||= []).push(n.id); });
  const layerCounts = Object.values(byLayer);
  const maxCount = Math.max(1, ...layerCounts.map(a => a.length));
  const totalW = maxCount * NODE_W + (maxCount - 1) * H_GAP;

  const pos: Record<string, { x: number; y: number }> = {};
  Object.entries(byLayer).forEach(([l, idsInLayer]) => {
    const width = idsInLayer.length * NODE_W + (idsInLayer.length - 1) * H_GAP;
    const offsetX = (totalW - width) / 2;
    idsInLayer.forEach((id, i) => {
      pos[id] = {
        x: PAD + offsetX + i * (NODE_W + H_GAP),
        y: PAD + Number(l) * (NODE_H + V_GAP),
      };
    });
  });
  return pos;
}

/** 画布总尺寸（供 SVG 设定 width/height）。 */
export function layoutSize(positions: Record<string, { x: number; y: number }>): { w: number; h: number } {
  let w = 0, h = 0;
  Object.values(positions).forEach(p => {
    w = Math.max(w, p.x + NODE_W);
    h = Math.max(h, p.y + NODE_H);
  });
  return { w: w + PAD, h: h + PAD };
}
