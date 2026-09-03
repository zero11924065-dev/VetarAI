/**
 * 0.2.1（TS-119）：工作流节点配置表单（节点列表式编辑）。
 *
 * 选中画布节点后在右侧编辑其属性；支持新增节点/连线/删除。
 * 节点类型与后端 schema.py 的 NODE_TYPES 一致。
 */
import React, { useState } from 'react';
import { colors, fonts, radius, input, textarea, select, btnPrimary, btnSecondary, btnDangerSoft } from '../theme';
import { Icon } from '../Icon';

const NODE_TYPE_OPTIONS = [
  { value: 'inference', label: '推理（模型纯调用）' },
  { value: 'tool', label: '工具（写文件等）' },
  { value: 'condition', label: '条件分支' },
  { value: 'parallel', label: '并行' },
  { value: 'loop', label: '循环' },
  { value: 'approval', label: '人工审批' },
  { value: 'file_input', label: '文件输入（读本机文件）' },
  { value: 'file_output', label: '文件输出（保存到本机）' },
  { value: 'end', label: '结束' },
];

const CONDITION_OPS = [
  { value: 'contains', label: '包含' },
  { value: 'not_contains', label: '不包含' },
  { value: 'equals', label: '等于' },
  { value: 'starts_with', label: '开头是' },
  { value: 'regex', label: '正则匹配' },
  { value: 'empty', label: '为空' },
  { value: 'not_empty', label: '非空' },
];

const FIELD_LABEL: React.CSSProperties = {
  fontSize: 12, color: colors.textSecondary, margin: '10px 0 4px', display: 'block', fontWeight: 500,
};

interface Props {
  definition: any;
  onChange: (definition: any) => void;
  selectedNodeId: string | null;
  models: string[];
  onClose: () => void;
}

export function WorkflowEditor({ definition, onChange, selectedNodeId, models, onClose }: Props) {
  const [newNodeType, setNewNodeType] = useState('inference');
  const [edgeFrom, setEdgeFrom] = useState('');
  const [edgeTo, setEdgeTo] = useState('');
  const [edgeWhen, setEdgeWhen] = useState('');

  const nodes: any[] = definition.nodes || [];
  const edges: any[] = definition.edges || [];
  const node = nodes.find((n: any) => n.id === selectedNodeId) || null;

  const patchNode = (id: string, patch: Record<string, any>) => {
    onChange({
      ...definition,
      nodes: nodes.map((n: any) => (n.id === id ? { ...n, ...patch } : n)),
    });
  };

  const addNode = () => {
    const idx = nodes.length + 1;
    let id = `n${idx}`;
    while (nodes.some((n: any) => n.id === id)) id = `${id}_${Math.floor(Math.random() * 900 + 100)}`;
    const labelMap: Record<string, string> = {
      inference: '推理节点', tool: '工具节点', condition: '条件分支',
      parallel: '并行节点', loop: '循环节点', approval: '人工审批',
      file_input: '文件输入', file_output: '文件输出', end: '结束',
    };
    const nn: any = { id, type: newNodeType, label: labelMap[newNodeType] || id };
    if (newNodeType === 'inference') { nn.model = models[0] || ''; nn.prompt = ''; nn.retry = 0; }
    if (newNodeType === 'tool') { nn.tool = 'write_file'; nn.args = {}; }
    if (newNodeType === 'condition') { nn.match = { variable: '', operator: 'contains', value: '' }; }
    if (newNodeType === 'parallel') { nn.branches = []; }
    if (newNodeType === 'loop') { nn.items = ''; nn.branch = ''; }
    if (newNodeType === 'approval') { nn.message = '请确认是否继续。'; }
    if (newNodeType === 'file_input') { nn.path = ''; nn.extensions = ''; nn.recursive = false; }
    if (newNodeType === 'file_output') { nn.dir = ''; nn.filename = ''; nn.content = ''; }
    onChange({ ...definition, nodes: [...nodes, nn] });
  };

  const removeNode = (id: string) => {
    onChange({
      nodes: nodes.filter((n: any) => n.id !== id),
      edges: edges.filter((e: any) => e.from !== id && e.to !== id),
    });
  };

  const addEdge = () => {
    if (!edgeFrom || !edgeTo || edgeFrom === edgeTo) return;
    if (edges.some((e: any) => e.from === edgeFrom && e.to === edgeTo && (e.when || '') === (edgeWhen || ''))) return;
    const ne: any = { from: edgeFrom, to: edgeTo };
    if (edgeWhen) ne.when = edgeWhen;
    onChange({ ...definition, edges: [...edges, ne] });
    setEdgeWhen('');
  };

  const removeEdge = (idx: number) => {
    onChange({ ...definition, edges: edges.filter((_: any, i: number) => i !== idx) });
  };

  const nodeIds = nodes.map((n: any) => `${n.id}（${n.label || n.type}）`);

  return (
    <div style={{ width: 320, borderLeft: `1px solid ${colors.borderDefault}`, background: colors.bgCard, display: 'flex', flexDirection: 'column', overflow: 'hidden' }}>
      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', padding: '10px 12px', borderBottom: `1px solid ${colors.borderSubtle}` }}>
        <span style={{ fontSize: 13, fontWeight: 600 }}>节点配置</span>
        <button onClick={onClose} style={{ border: 'none', background: 'transparent', cursor: 'pointer', color: colors.textTertiary, fontSize: 14 }}>✕</button>
      </div>
      <div style={{ flex: 1, overflowY: 'auto', padding: '0 12px 16px' }}>
        {node ? (
          <>
            <label style={FIELD_LABEL}>节点名称</label>
            <input style={{ ...input, width: '100%' }} value={node.label || ''}
              onChange={e => patchNode(node.id, { label: e.target.value })} />
            <label style={FIELD_LABEL}>节点类型</label>
            <div style={{ fontSize: 12, color: colors.textTertiary }}>{node.type}{node.id ? `（id: ${node.id}）` : ''}</div>

            {node.type === 'inference' && (
              <>
                <label style={FIELD_LABEL}>模型</label>
                <select style={{ ...select, width: '100%' }} value={node.model || ''}
                  onChange={e => patchNode(node.id, { model: e.target.value })}>
                  <option value="">（选择模型）</option>
                  {models.map(m => <option key={m} value={m}>{m}</option>)}
                </select>
                <label style={FIELD_LABEL}>提示词（可用 {'{{params.名称}}'}、{'{{item}}'} 等变量）</label>
                <textarea style={{ ...textarea, width: '100%', minHeight: 80 }} value={node.prompt || ''}
                  onChange={e => patchNode(node.id, { prompt: e.target.value })} />
                <label style={FIELD_LABEL}>图片变量（可选，如 {'{{params.images}}'}）</label>
                <input style={{ ...input, width: '100%' }} value={node.images || ''}
                  placeholder="留空 = 无图片"
                  onChange={e => patchNode(node.id, { images: e.target.value || undefined })} />
                <label style={FIELD_LABEL}>失败重试次数</label>
                <input style={{ ...input, width: 80 }} type="number" min={0} max={5} value={node.retry ?? 0}
                  onChange={e => patchNode(node.id, { retry: Math.max(0, Math.min(5, Number(e.target.value) || 0)) })} />
              </>
            )}

            {node.type === 'tool' && (
              <>
                <label style={FIELD_LABEL}>工具名（write_file / read_file / list_dir / create_dir）</label>
                <input style={{ ...input, width: '100%' }} value={node.tool || ''}
                  onChange={e => patchNode(node.id, { tool: e.target.value })} />
                <label style={FIELD_LABEL}>参数（JSON，值可用 {'{{...}}'} 变量）</label>
                <textarea style={{ ...textarea, width: '100%', minHeight: 70, fontFamily: fonts.mono, fontSize: 12 }}
                  value={typeof node.args === 'object' ? JSON.stringify(node.args, null, 2) : String(node.args || '{}')}
                  onChange={e => {
                    try { patchNode(node.id, { args: JSON.parse(e.target.value) }); } catch { /* 输入中途不强制合法 */ }
                  }} />
              </>
            )}

            {node.type === 'condition' && (
              <>
                <label style={FIELD_LABEL}>判断方式</label>
                <div style={{ display: 'flex', gap: 8 }}>
                  <button style={{ ...btnSecondary, height: 24, fontSize: 12, background: !node.model ? colors.accentBg : undefined }}
                    onClick={() => patchNode(node.id, { model: undefined, prompt: undefined })}>静态匹配</button>
                  <button style={{ ...btnSecondary, height: 24, fontSize: 12, background: node.model ? colors.accentBg : undefined }}
                    onClick={() => patchNode(node.id, { model: node.model || (models[0] || ''), prompt: node.prompt || '' })}>动态裁判（模型判定）</button>
                </div>
                {node.model ? (
                  <>
                    <label style={FIELD_LABEL}>裁判模型</label>
                    <select style={{ ...select, width: '100%' }} value={node.model || ''}
                      onChange={e => patchNode(node.id, { model: e.target.value })}>
                      {models.map(m => <option key={m} value={m}>{m}</option>)}
                    </select>
                    <label style={FIELD_LABEL}>判定提示词（输出内容 = 分支 when 标签）</label>
                    <textarea style={{ ...textarea, width: '100%', minHeight: 60 }} value={node.prompt || ''}
                      onChange={e => patchNode(node.id, { prompt: e.target.value })} />
                    <div style={{ fontSize: 11, color: colors.textTertiary, marginTop: 4 }}>
                      连线 when 填模型输出的分支名（如"是"/"否"），动态分支。
                    </div>
                  </>
                ) : (
                  <>
                    <label style={FIELD_LABEL}>匹配变量（如 {'{{n1.output}}'}）</label>
                    <input style={{ ...input, width: '100%' }} value={node.match?.variable || ''}
                      onChange={e => patchNode(node.id, { match: { ...(node.match || {}), variable: e.target.value } })} />
                    <label style={FIELD_LABEL}>运算符</label>
                    <select style={{ ...select, width: '100%' }} value={node.match?.operator || 'contains'}
                      onChange={e => patchNode(node.id, { match: { ...(node.match || {}), operator: e.target.value } })}>
                      {CONDITION_OPS.map(o => <option key={o.value} value={o.value}>{o.label}</option>)}
                    </select>
                    {!['empty', 'not_empty'].includes(node.match?.operator || 'contains') && (
                      <>
                        <label style={FIELD_LABEL}>匹配值</label>
                        <input style={{ ...input, width: '100%' }} value={node.match?.value || ''}
                          onChange={e => patchNode(node.id, { match: { ...(node.match || {}), value: e.target.value } })} />
                      </>
                    )}
                    <div style={{ fontSize: 11, color: colors.textTertiary, marginTop: 4 }}>
                      命中走 when="true" 的边，不命中走 when="false"。
                    </div>
                  </>
                )}
              </>
            )}

            {node.type === 'parallel' && (
              <>
                <label style={FIELD_LABEL}>并行分支（节点 id，逗号分隔）</label>
                <input style={{ ...input, width: '100%' }} value={(node.branches || []).join(', ')}
                  onChange={e => patchNode(node.id, { branches: e.target.value.split(/[,，]/).map((s: string) => s.trim()).filter(Boolean) })} />
                <div style={{ fontSize: 11, color: colors.textTertiary, marginTop: 4 }}>可选：{nodeIds.join('、') || '（暂无节点）'}</div>
              </>
            )}

            {node.type === 'loop' && (
              <>
                <label style={FIELD_LABEL}>列表变量（如 {'{{params.list}}'}）</label>
                <input style={{ ...input, width: '100%' }} value={node.items || ''}
                  onChange={e => patchNode(node.id, { items: e.target.value })} />
                <label style={FIELD_LABEL}>循环体节点 id（内部可用 {'{{item}}'}）</label>
                <input style={{ ...input, width: '100%' }} value={node.branch || ''}
                  onChange={e => patchNode(node.id, { branch: e.target.value.trim() })} />
                <div style={{ fontSize: 11, color: colors.textTertiary, marginTop: 4 }}>可选：{nodeIds.join('、') || '（暂无节点）'}</div>
              </>
            )}

            {node.type === 'approval' && (
              <>
                <label style={FIELD_LABEL}>审批提示（可用变量）</label>
                <textarea style={{ ...textarea, width: '100%', minHeight: 60 }} value={node.message || ''}
                  onChange={e => patchNode(node.id, { message: e.target.value })} />
              </>
            )}

            {node.type === 'file_input' && (
              <>
                <label style={FIELD_LABEL}>本机路径（文件或文件夹，支持 {'{{params.名称}}'}）</label>
                <div style={{ display: 'flex', gap: 6 }}>
                  <input style={{ ...input, flex: 1 }} value={node.path || ''} placeholder="/Users/你/材料/聊天记录"
                    onChange={e => patchNode(node.id, { path: e.target.value })} />
                  <button style={{ ...btnSecondary, height: 30, fontSize: 12, padding: '0 8px', flexShrink: 0 }}
                    onClick={async () => {
                      const bridge = (window as any).subagent;
                      if (bridge?.chooseInputFile) {
                        const f = await bridge.chooseInputFile().catch(() => null);
                        if (f) patchNode(node.id, { path: f });
                      } else if (bridge?.chooseWorkingDir) {
                        const d = await bridge.chooseWorkingDir().catch(() => null);
                        if (d) patchNode(node.id, { path: d });
                      }
                    }}>选择</button>
                </div>
                <label style={FIELD_LABEL}>扩展名过滤（逗号分隔，留空 = 全部）</label>
                <input style={{ ...input, width: '100%' }} value={node.extensions || ''} placeholder="jpg, png, pdf"
                  onChange={e => patchNode(node.id, { extensions: e.target.value })} />
                <label style={FIELD_LABEL}>
                  <input type="checkbox" checked={!!node.recursive}
                    onChange={e => patchNode(node.id, { recursive: e.target.checked })}
                    style={{ marginRight: 6, verticalAlign: 'middle' }} />
                  文件夹时递归搜索子目录
                </label>
                <div style={{ fontSize: 11, color: colors.textTertiary, marginTop: 6 }}>
                  输出：文件路径列表，可用循环节点 + {'{{item}}'} 逐个处理。
                </div>
              </>
            )}

            {node.type === 'file_output' && (
              <>
                <label style={FIELD_LABEL}>保存目录（支持 {'{{变量}}'}）</label>
                <div style={{ display: 'flex', gap: 6 }}>
                  <input style={{ ...input, flex: 1 }} value={node.dir || ''} placeholder="/Users/你/材料/聊天文本"
                    onChange={e => patchNode(node.id, { dir: e.target.value })} />
                  <button style={{ ...btnSecondary, height: 30, fontSize: 12, padding: '0 8px', flexShrink: 0 }}
                    onClick={async () => {
                      const bridge = (window as any).subagent;
                      if (bridge?.chooseWorkingDir) {
                        const d = await bridge.chooseWorkingDir().catch(() => null);
                        if (d) patchNode(node.id, { dir: d });
                      }
                    }}>选择</button>
                </div>
                <label style={FIELD_LABEL}>文件名（支持 {'{{item}}'} / {'{{item_index}}'} / {'{{节点.output}}'}）</label>
                <input style={{ ...input, width: '100%' }} value={node.filename || ''} placeholder="{{item_index}}.md"
                  onChange={e => patchNode(node.id, { filename: e.target.value })} />
                <label style={FIELD_LABEL}>文件内容（支持 {'{{变量}}'}）</label>
                <textarea style={{ ...textarea, width: '100%', minHeight: 70, fontFamily: fonts.mono, fontSize: 12 }}
                  value={node.content || ''} placeholder="{{ocr.output}}"
                  onChange={e => patchNode(node.id, { content: e.target.value })} />
                <div style={{ fontSize: 11, color: colors.textTertiary, marginTop: 6 }}>
                  循环节点内使用时，每一轮写入一个文件（文件名用 {'{{item_index}}'} 或 {'{{item}}'} 区分）。
                </div>
              </>
            )}

            {node.type === 'end' && (
              <>
                <label style={FIELD_LABEL}>结果引用（如 {'{{n1.output}}'}，留空 = 无结果）</label>
                <input style={{ ...input, width: '100%' }} value={node.output || ''}
                  onChange={e => patchNode(node.id, { output: e.target.value || undefined })} />
              </>
            )}

            {node.type !== 'start' && (
              <div style={{ marginTop: 14 }}>
                <button style={{ ...btnDangerSoft, height: 26, fontSize: 12 }} onClick={() => removeNode(node.id)}>
                  <Icon name="trash" size={13} /> 删除此节点
                </button>
              </div>
            )}
          </>
        ) : (
          <div style={{ fontSize: 12, color: colors.textTertiary, padding: '12px 0' }}>
            点击画布中的节点进行配置，或在下方新增节点。
          </div>
        )}

        <div style={{ borderTop: `1px solid ${colors.borderSubtle}`, marginTop: 16, paddingTop: 10 }}>
          <div style={{ fontSize: 12, fontWeight: 600, marginBottom: 6 }}>新增节点</div>
          <div style={{ display: 'flex', gap: 6 }}>
            <select style={{ ...select, flex: 1 }} value={newNodeType} onChange={e => setNewNodeType(e.target.value)}>
              {NODE_TYPE_OPTIONS.map(o => <option key={o.value} value={o.value}>{o.label}</option>)}
            </select>
            <button style={{ ...btnPrimary, height: 26, fontSize: 12 }} onClick={addNode}>添加</button>
          </div>
        </div>

        <div style={{ borderTop: `1px solid ${colors.borderSubtle}`, marginTop: 14, paddingTop: 10 }}>
          <div style={{ fontSize: 12, fontWeight: 600, marginBottom: 6 }}>连线</div>
          <div style={{ display: 'flex', gap: 6, marginBottom: 6 }}>
            <select style={{ ...select, flex: 1, fontSize: 11 }} value={edgeFrom} onChange={e => setEdgeFrom(e.target.value)}>
              <option value="">起点…</option>
              {nodes.map((n: any) => <option key={n.id} value={n.id}>{n.label || n.id}</option>)}
            </select>
            <span style={{ color: colors.textTertiary, fontSize: 12, alignSelf: 'center' }}>→</span>
            <select style={{ ...select, flex: 1, fontSize: 11 }} value={edgeTo} onChange={e => setEdgeTo(e.target.value)}>
              <option value="">终点…</option>
              {nodes.map((n: any) => <option key={n.id} value={n.id}>{n.label || n.id}</option>)}
            </select>
          </div>
          <div style={{ display: 'flex', gap: 6 }}>
            <input style={{ ...input, flex: 1, fontSize: 11 }} placeholder="分支标签 when（可选）" value={edgeWhen}
              onChange={e => setEdgeWhen(e.target.value)} />
            <button style={{ ...btnPrimary, height: 26, fontSize: 12 }} onClick={addEdge}>连线</button>
          </div>
          <div style={{ marginTop: 8 }}>
            {edges.map((e: any, i: number) => (
              <div key={i} style={{ display: 'flex', alignItems: 'center', gap: 4, fontSize: 11, color: colors.textSecondary, padding: '2px 0' }}>
                <span style={{ flex: 1 }}>{e.from} → {e.to}{e.when ? `（${e.when}）` : ''}</span>
                <button onClick={() => removeEdge(i)} style={{ border: 'none', background: 'transparent', cursor: 'pointer', color: colors.dangerText, fontSize: 11 }}>删除</button>
              </div>
            ))}
          </div>
        </div>
      </div>
    </div>
  );
}
