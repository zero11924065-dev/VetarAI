/**
 * 0.2.1（TS-119）：工作流可视化画布（SVG，纯展示）。
 *
 * 自动布局（拓扑分层）渲染节点卡片与连线；条件边标注分支名；
 * 点击节点 → onSelectNode(id) 打开侧边配置表单。
 * 运行时态：nodeStatus 标记节点 进行中/成功/失败。
 */
import React from 'react';
import { colors, fonts, radius } from '../theme';
import { layoutWorkflow, layoutSize, NODE_W, NODE_H, WfDefinition } from '../lib/workflowLayout';

const TYPE_META: Record<string, { label: string; color: string }> = {
  start: { label: '开始', color: colors.ok },
  inference: { label: '推理', color: colors.accent },
  tool: { label: '工具', color: colors.warn },
  condition: { label: '条件', color: colors.warn },
  parallel: { label: '并行', color: '#8B5CF6' },
  loop: { label: '循环', color: '#8B5CF6' },
  approval: { label: '审批', color: colors.danger },
  file_input: { label: '文件输入', color: '#0EA5E9' },
  file_output: { label: '文件输出', color: '#0EA5E9' },
  end: { label: '结束', color: colors.textSecondary },
};

export type NodeStatus = 'pending' | 'running' | 'done' | 'error';

interface Props {
  definition: WfDefinition;
  selectedNodeId?: string | null;
  nodeStatus?: Record<string, NodeStatus>;
  onSelectNode?: (id: string) => void;
}

export function WorkflowCanvas({ definition, selectedNodeId, nodeStatus, onSelectNode }: Props) {
  const positions = React.useMemo(() => layoutWorkflow(definition), [definition]);
  const { w, h } = React.useMemo(() => layoutSize(positions), [positions]);
  const nodes = definition.nodes || [];
  const edges = definition.edges || [];
  const nodeById = React.useMemo(() => {
    const m: Record<string, any> = {};
    nodes.forEach(n => { m[n.id] = n; });
    return m;
  }, [nodes]);

  const statusRing = (id: string): string | null => {
    const st = nodeStatus?.[id];
    if (st === 'running') return colors.accent;
    if (st === 'done') return colors.ok;
    if (st === 'error') return colors.danger;
    return null;
  };

  return (
    <div style={{ overflow: 'auto', background: colors.bgApp, flex: 1 }}>
      <svg width={Math.max(w, 480)} height={Math.max(h, 240)} style={{ display: 'block' }}>
        <defs>
          <marker id="wf-arrow" markerWidth="9" markerHeight="9" refX="8" refY="4.5" orient="auto">
            <path d="M0,0 L9,4.5 L0,9 z" fill={colors.borderStrong} />
          </marker>
        </defs>
        {/* 连线 */}
        {edges.map((e, i) => {
          const p1 = positions[e.from];
          const p2 = positions[e.to];
          if (!p1 || !p2) return null;
          const x1 = p1.x + NODE_W / 2;
          const y1 = p1.y + NODE_H;
          const x2 = p2.x + NODE_W / 2;
          const y2 = p2.y;
          const midY = (y1 + y2) / 2;
          const path = Math.abs(x1 - x2) < 4
            ? `M ${x1} ${y1} L ${x2} ${y2 - 6}`
            : `M ${x1} ${y1} C ${x1} ${midY}, ${x2} ${midY}, ${x2} ${y2 - 6}`;
          return (
            <g key={`e${i}`}>
              <path d={path} fill="none" stroke={colors.borderStrong} strokeWidth={1.5} markerEnd="url(#wf-arrow)" />
              {e.when ? (
                <text x={(x1 + x2) / 2 + 8} y={midY} fontSize={10} fill={colors.textSecondary} fontFamily={fonts.base}>
                  {e.when}
                </text>
              ) : null}
            </g>
          );
        })}
        {/* 节点卡片 */}
        {nodes.map(n => {
          const p = positions[n.id];
          if (!p) return null;
          const meta = TYPE_META[n.type] || { label: n.type, color: colors.textSecondary };
          const sel = selectedNodeId === n.id;
          const ring = statusRing(n.id);
          return (
            <g key={n.id} style={{ cursor: 'pointer' }} onClick={() => onSelectNode?.(n.id)}>
              <rect x={p.x} y={p.y} width={NODE_W} height={NODE_H} rx={radius.m}
                fill={colors.bgCard}
                stroke={ring || (sel ? colors.accent : colors.borderDefault)}
                strokeWidth={sel || ring ? 2 : 1} />
              <rect x={p.x} y={p.y} width={4} height={NODE_H} rx={2} fill={meta.color} />
              <text x={p.x + 14} y={p.y + 21} fontSize={12} fontWeight={600} fill={colors.textPrimary} fontFamily={fonts.base}>
                {(n.label || meta.label).slice(0, 14)}
              </text>
              <text x={p.x + 14} y={p.y + 38} fontSize={10.5} fill={colors.textTertiary} fontFamily={fonts.base}>
                {meta.label}{n.model ? ` · ${String(n.model).split(':')[0]}` : ''}
              </text>
            </g>
          );
        })}
      </svg>
    </div>
  );
}
