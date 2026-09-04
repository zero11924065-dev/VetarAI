/*
 * VetarAI - Local-first multi-agent orchestration application
 * Copyright (C) 2026 zero11924065-dev
 *
 * This file is part of VetarAI.
 *
 * VetarAI is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * VetarAI is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with VetarAI. If not, see <https://www.gnu.org/licenses/>.
 */
/**
 * checkpoint-078 TS-119 工作流前端 专项测试。
 *
 * 覆盖：
 *  F1 布局算法：线性流程分层 / 条件分支并排 / 并行分支并排 / 孤立节点兜底 / 画布尺寸
 *  F2 模块导航：渲染两个一级模块、点击切换回调、选中态
 *  F3 画布渲染：节点卡片数量与标签、连线数量、条件边 when 标签、点击节点回调
 */
import { describe, it, expect, vi } from 'vitest';
import { render, screen, fireEvent } from '@testing-library/react';
import React from 'react';
import { layoutWorkflow, layoutSize, NODE_W, NODE_H } from '../lib/workflowLayout';
import { ModuleNav } from '../panels/ModuleNav';
import { WorkflowCanvas } from '../panels/WorkflowCanvas';

const linear = {
  nodes: [
    { id: 'start', type: 'start', label: '开始' },
    { id: 'n1', type: 'inference', label: '识别', model: 'glm-ocr:latest' },
    { id: 'end', type: 'end', label: '结束' },
  ],
  edges: [{ from: 'start', to: 'n1' }, { from: 'n1', to: 'end' }],
  params: {},
};

const branched = {
  nodes: [
    { id: 'start', type: 'start' },
    { id: 'cond', type: 'condition', label: '判断' },
    { id: 'yes', type: 'end', label: '命中' },
    { id: 'no', type: 'end', label: '未中' },
  ],
  edges: [
    { from: 'start', to: 'cond' },
    { from: 'cond', to: 'yes', when: 'true' },
    { from: 'cond', to: 'no', when: 'false' },
  ],
  params: {},
};

describe('工作流布局算法（TS-119）', () => {
  it('线性流程：三节点纵向分层，x 居中一致', () => {
    const pos = layoutWorkflow(linear);
    expect(pos['start'].y).toBeLessThan(pos['n1'].y);
    expect(pos['n1'].y).toBeLessThan(pos['end'].y);
    expect(pos['start'].x).toBe(pos['n1'].x);
    expect(pos['n1'].x).toBe(pos['end'].x);
  });

  it('条件分支：两个分支节点同层并排（y 相同、x 不同）', () => {
    const pos = layoutWorkflow(branched);
    expect(pos['yes'].y).toBe(pos['no'].y);
    expect(pos['yes'].x).not.toBe(pos['no'].x);
    expect(pos['cond'].y).toBeLessThan(pos['yes'].y);
  });

  it('并行分支：branches 视为隐式边参与分层', () => {
    const defn = {
      nodes: [
        { id: 'start', type: 'start' },
        { id: 'p', type: 'parallel', label: '并行', branches: ['a', 'b'] },
        { id: 'a', type: 'inference', label: 'A', model: 'm' },
        { id: 'b', type: 'inference', label: 'B', model: 'm' },
        { id: 'end', type: 'end' },
      ],
      edges: [
        { from: 'start', to: 'p' },
        { from: 'a', to: 'end' },
        { from: 'b', to: 'end' },
      ],
      params: {},
    };
    const pos = layoutWorkflow(defn);
    expect(pos['a'].y).toBe(pos['b'].y);       // 并行分支同层
    expect(pos['p'].y).toBeLessThan(pos['a'].y);
    expect(pos['a'].y).toBeLessThan(pos['end'].y);
  });

  it('孤立节点：不丢失，排在可达节点之下', () => {
    const defn = {
      nodes: [
        { id: 'start', type: 'start' },
        { id: 'end', type: 'end' },
        { id: 'iso', type: 'inference', label: '孤岛', model: 'm' },
      ],
      edges: [{ from: 'start', to: 'end' }],
      params: {},
    };
    const pos = layoutWorkflow(defn);
    expect(pos['iso']).toBeDefined();
    expect(pos['iso'].y).toBeGreaterThan(pos['end'].y);
  });

  it('画布尺寸：包含所有节点', () => {
    const pos = layoutWorkflow(linear);
    const { w, h } = layoutSize(pos);
    expect(w).toBeGreaterThanOrEqual(NODE_W);
    expect(h).toBeGreaterThanOrEqual(NODE_H * 3);
  });

  it('空定义：返回空布局不报错', () => {
    expect(layoutWorkflow({ nodes: [], edges: [] })).toEqual({});
    expect(layoutSize({})).toEqual({ w: 24, h: 24 });
  });
});

describe('一级模块导航（TS-119）', () => {
  it('渲染两个一级模块', () => {
    render(<ModuleNav active="intelligence" onSelect={() => {}} />);
    expect(screen.getByText('智能中心')).toBeTruthy();
    expect(screen.getByText('流程中心')).toBeTruthy();
  });

  it('点击模块触发切换回调', () => {
    const onSelect = vi.fn();
    render(<ModuleNav active="intelligence" onSelect={onSelect} />);
    fireEvent.click(screen.getByText('流程中心'));
    expect(onSelect).toHaveBeenCalledWith('workflow');
  });
});

describe('工作流画布（TS-119）', () => {
  it('渲染全部节点卡片与连线', () => {
    const { container } = render(<WorkflowCanvas definition={linear as any} />);
    const rects = container.querySelectorAll('rect');
    // 每个节点 2 个 rect（主体 + 左侧色条）→ 3 节点 = 6
    expect(rects.length).toBe(6);
    expect(screen.getByText('识别')).toBeTruthy();
    // 连线 path 数量 = 边数
    const paths = container.querySelectorAll('path');
    expect(paths.length).toBeGreaterThanOrEqual(2);
  });

  it('条件边渲染 when 标签', () => {
    const { container } = render(<WorkflowCanvas definition={branched as any} />);
    expect(container.textContent).toContain('true');
    expect(container.textContent).toContain('false');
  });

  it('点击节点触发 onSelectNode', () => {
    const onSelect = vi.fn();
    render(<WorkflowCanvas definition={linear as any} onSelectNode={onSelect} />);
    fireEvent.click(screen.getByText('识别'));
    expect(onSelect).toHaveBeenCalledWith('n1');
  });

  it('运行时态：running 节点高亮环', () => {
    const { container } = render(
      <WorkflowCanvas definition={linear as any} nodeStatus={{ n1: 'running' }} />);
    // 运行中节点边框加粗为主色（stroke-width=2）
    const highlighted = Array.from(container.querySelectorAll('rect'))
      .filter(r => r.getAttribute('stroke-width') === '2');
    expect(highlighted.length).toBeGreaterThan(0);
  });
});
