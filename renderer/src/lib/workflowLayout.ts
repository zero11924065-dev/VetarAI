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

  // 分层：最长路径松弛（限制轮数防环）
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
