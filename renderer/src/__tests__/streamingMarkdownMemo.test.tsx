/*
 * VetarAI - Local-first multi-agent orchestration application
 * Copyright (C) 2026 zero11924065-dev
 * GPL-3.0-or-later（见仓库 LICENSE）
 */
/**
 * F2（0.4.23 安全区，checkpoint-110）：StreamingMarkdown memo 化复现测试。
 *
 * 主因（`36-…测量操作卡.md` 5.7 真机数据坐实）：流式/思考期每个 SSE 事件都 setLocalMessages
 * → 重渲染整个消息列表（实测 93~95 条），**每条 assistant 都重新走 ReactMarkdown 完整解析**。
 * 其中 94 条 text 一个字没变，解析纯属浪费——这是 Electron 渲染进程烧满一核（实测 ~103%）的主成本之一。
 *
 * 修法：`React.memo` 包裹 StreamingMarkdown，text 不变则跳过重渲染与重解析（叶子组件，
 * 输出仅依赖 text，不改 DOM/样式 → 与 A12 零冲突）。
 *
 * 测法：mock `react-markdown` 统计它被渲染（= 一次完整解析）的次数。
 *   · M2：父组件重渲染但 text 不变 → 改前每次重渲染都重解析（红，6 次）；加 memo 后跳过（绿，1 次）。
 *   · M3：text 变化时 memo **不得误伤**——内容必须更新（仍重新解析），否则界面停在旧内容。
 *
 * 运行：node node_modules/vitest/vitest.mjs run src/__tests__/streamingMarkdownMemo.test.tsx
 */
import { describe, it, expect, vi, beforeEach } from 'vitest';

// mock react-markdown：统计它被渲染（= 一次完整 Markdown 解析）的次数。
// ⛔ 用 vi.hoisted 让 spy 在 mock factory 提升后仍可引用；factory 内用动态 import 取 React（ESM 安全）。
const mdRenderSpy = vi.hoisted(() => vi.fn());
vi.mock('react-markdown', async () => {
  const React = await import('react');
  return {
    default: (props: any) => {
      mdRenderSpy();
      return React.createElement('div', { 'data-testid': 'md-out' }, String(props.children ?? ''));
    },
  };
});

import { render, screen, fireEvent } from '@testing-library/react';
import React, { useState } from 'react';
import { StreamingMarkdown } from '../panels/ChatPanel';

beforeEach(() => { mdRenderSpy.mockClear(); });

const TEXT = '这是**一段** markdown 正文，内容保持不变';

/**
 * 测试夹具：一个会因**无关 state** 重渲染的父组件，内含一个 text 受控的 StreamingMarkdown。
 * 点「重渲染父组件」模拟"消息列表整体重渲染"（真实场景：任一 SSE 事件 → setLocalMessages → 整列表重渲染），
 * 此时 StreamingMarkdown 的 text **没变** → memo 应跳过它。
 */
function Harness({ initialText }: { initialText: string }) {
  const [text, setText] = useState(initialText);
  const [tick, setTick] = useState(0);
  return (
    <div>
      <button data-testid="rerender" onClick={() => setTick(t => t + 1)}>重渲染父组件</button>
      <button data-testid="changetext" onClick={() => setText(TEXT + '（已修改）')}>改文本</button>
      <span data-testid="tick">{tick}</span>
      <StreamingMarkdown text={text} />
    </div>
  );
}

describe('F2 StreamingMarkdown memo 化（text 不变则跳过 ReactMarkdown 重解析）', () => {
  it('M1 首次渲染解析一次', () => {
    render(<Harness initialText={TEXT} />);
    expect(mdRenderSpy).toHaveBeenCalledTimes(1);
    expect(screen.getByTestId('md-out').textContent).toContain('一段');
  });

  it('M2 ⛔ 父组件重渲染但 text 不变 → ReactMarkdown 不得被再次调用（memo 生效）', () => {
    render(<Harness initialText={TEXT} />);
    expect(mdRenderSpy).toHaveBeenCalledTimes(1);
    // 模拟"消息列表整体重渲染"：点 5 次触发父组件 setState（text 始终不变）
    for (let i = 0; i < 5; i++) fireEvent.click(screen.getByTestId('rerender'));
    // 前置：父组件确实重渲染了（tick 变 5），否则本用例没测到东西
    expect(screen.getByTestId('tick').textContent).toBe('5');
    // ⛔ 核心断言：text 没变 → memo 应跳过，ReactMarkdown 仍只调用 1 次。
    //   改前（无 memo）：6 次（1 首次 + 5 次重渲染各重解析一遍）→ 红。
    expect(mdRenderSpy).toHaveBeenCalledTimes(1);
  });

  it('M3 ⛔ text 变化时 memo 不得误伤——内容必须更新（仍重新解析）', () => {
    render(<Harness initialText={TEXT} />);
    expect(mdRenderSpy).toHaveBeenCalledTimes(1);
    fireEvent.click(screen.getByTestId('changetext'));
    // text 变了 → 必须重新解析（否则界面停在旧内容 = memo 把组件冻死了）
    expect(mdRenderSpy).toHaveBeenCalledTimes(2);
    expect(screen.getByTestId('md-out').textContent).toContain('已修改');
  });
});
