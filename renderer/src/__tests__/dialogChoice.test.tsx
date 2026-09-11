/*
 * VetarAI - Local-first multi-agent orchestration application
 * Copyright (C) 2026 zero11924065-dev
 * GPL-3.0-or-later（见仓库 LICENSE）
 */
/**
 * A11/A13（0.4.22）专项：choiceDialog —— 多按钮选择弹窗（Dialog.tsx 新增能力）。
 *
 * 为什么需要它：既有 confirmDialog 只有"确认/取消"两态，撑不起 A11 同名冲突的
 * 三选一（覆盖 / 改名并存 / 跳过）。
 *
 * ⛔ 本套件锁的关键回归点（开发时真踩过）：
 *   ChoiceHost 里的 useEffect 若写在 `if (!state) return null` **之后**，就是条件调用 hooks
 *   → 本组件在"有弹窗/无弹窗"两种渲染间 hooks 数量不一致
 *   → React 抛 "Rendered fewer hooks than during the previous render" 直接崩。
 *   既有 DialogHost/PromptHost 都是先 hooks 后 return null；新组件必须一致。
 *   ⛔ 光测"打开弹窗能用"抓不到这个 bug —— 必须**先无弹窗渲染一次、再打开、再关闭**，
 *   走完 hooks 数量变化的完整往返。
 */
import { describe, it, expect, beforeEach } from 'vitest';
import { render, screen, waitFor, act, fireEvent } from '@testing-library/react';
import React from 'react';
import { choiceDialog } from '../Dialog';

/**
 * ⛔ Dialog.tsx 是**模块级单例**，弹窗渲染进 document.body（不在 render() 的容器里），
 * 且跨用例不自动卸载。每个用例必须自己收尾：
 *   1. 关掉弹窗（点取消/按钮/Esc 任一，触发 resolve）；
 *   2. 卸载承载组件并清掉 body 里残留的弹窗 DOM，否则会串到下一个用例
 *      （首轮就因此出现"上一个用例的弹窗还在，getByText 命中两个"）。
 */
function Probe() {
  // 先渲染一次「无弹窗」状态：这是 hooks 数量变化的第一拍，缺它就测不到崩溃
  return <div data-testid="host">host</div>;
}

let cleanup: (() => void) | null = null;

beforeEach(() => {
  if (cleanup) { cleanup(); cleanup = null; }
  // 清掉上个用例可能残留在 body 的弹窗
  document.querySelectorAll('[role="dialog"]').forEach(n => n.remove());
});

/** 渲染承载组件，返回 unmount。 */
function mountHost() {
  const { unmount } = render(<Probe />);
  cleanup = () => {
    unmount();
    document.querySelectorAll('[role="dialog"]').forEach(n => n.remove());
  };
  return unmount;
}

describe('A11 choiceDialog 多按钮选择弹窗', () => {
  it('D0 ⛔ 源码断言：ChoiceHost 的 hooks 必须在条件 return 之前（防 React 崩溃）', async () => {
    // ═══ 为什么必须用源码断言，而不是行为断言 ═══
    // 我曾写过一条"打开→关闭往返不崩"的行为断言（旧 D1），并**用变异实测证伪了它**：
    // 把 useEffect 挪到 `if (!state) return null` 之后（条件调用 hooks），该断言**仍然全绿**。
    // 根因：Dialog.tsx 用 `createRoot` 建的是**并发模式独立 React 根**，`root.render()`
    // 只是排程、不同步执行 → 那个该抛 "Rendered fewer hooks" 的渲染被推迟到 act() 之外，
    // 测试早已通过。跨独立根 + 并发排程的错误，行为层测试结构上抓不住。
    // ✅ 故改用源码断言（同后端 T10/T11 纪律）：锚定**实际代码顺序**，
    //    且锚点不含中文说明文字 → 注释里写"必须在前"不会让它假通过。
    const code = await import('../Dialog?raw').then(m => m.default as string);
    const host = code.split('function ChoiceHost(')[1];
    expect(host).toBeTruthy();
    // ⛔ 锚点必须带分号：ChoiceHost 的注释里**原样引用了** `if (!state) return null`
    //    （反引号包裹、无分号）→ 不带分号的 indexOf 会先命中注释（位置 127）而非真实
    //    语句（位置 263），断言方向整个反过来。首轮即因此红，教训：写"锚定实际形态"的
    //    源码断言时，⛔ 注释里也不要原样抄该形态，或锚点要能区分（这里是加分号）。
    const iReturn = host.indexOf('if (!state) return null;');
    const iEffect = host.indexOf('useEffect(');
    expect(iEffect).toBeGreaterThan(-1);
    expect(iReturn).toBeGreaterThan(-1);
    // ⛔ 核心：useEffect 必须**早于**条件 return
    expect(iEffect).toBeLessThan(iReturn);
    // ⛔ 反向锚定错误形态：条件 return 之后不得再出现 useEffect（那就是条件调用 hooks）
    expect(host.slice(iReturn).indexOf('useEffect(')).toBe(-1);
  });

  it('D1 打开→关闭的完整往返可正常渲染并 resolve（基本可用性）', async () => {
    mountHost();
    // 第一拍：无弹窗（ChoiceHost 走 `if (!state) return null`）
    expect(screen.queryByRole('dialog')).toBeNull();

    let p: Promise<string | null> | null = null;
    await act(async () => {
      p = choiceDialog({
        title: '知识目录已有同名文件',
        message: '报告.docx 已存在',
        options: [
          { value: 'overwrite', label: '覆盖同名文件', danger: true },
          { value: 'rename', label: '改名并存' },
          { value: 'skip', label: '跳过这些' },
        ],
      });
    });
    // 第二拍：有弹窗（hooks 数量与第一拍必须一致，否则 React 抛错）
    await waitFor(() => expect(screen.getByRole('dialog')).toBeTruthy());
    expect(screen.getByText('知识目录已有同名文件')).toBeTruthy();

    // 第三拍：关闭（回到无弹窗）—— 再次切换 hooks 数量
    await act(async () => { fireEvent.click(screen.getByText('跳过这些')); });
    await expect(p).resolves.toBe('skip');
    expect(screen.queryByRole('dialog')).toBeNull();
  });

  it('D2 点各按钮分别 resolve 对应的 value', async () => {
    for (const [label, value] of [['覆盖同名文件', 'overwrite'], ['改名并存', 'rename']] as const) {
      mountHost();
      let p: Promise<string | null> | null = null;
      await act(async () => {
        p = choiceDialog({
          title: '同名', message: 'x',
          options: [
            { value: 'overwrite', label: '覆盖同名文件' },
            { value: 'rename', label: '改名并存' },
          ],
        });
      });
      await waitFor(() => expect(screen.getByRole('dialog')).toBeTruthy());
      await act(async () => { fireEvent.click(screen.getByText(label)); });
      await expect(p).resolves.toBe(value);
      cleanup?.(); cleanup = null;
    }
  });

  it('D3 点「取消」resolve null（= 不处理，保留原文件）', async () => {
    mountHost();
    let p: Promise<string | null> | null = null;
    await act(async () => {
      p = choiceDialog({ title: '同名', message: 'x', cancelText: '不处理（保留原文件）',
                         options: [{ value: 'skip', label: '跳过这些' }] });
    });
    await waitFor(() => expect(screen.getByRole('dialog')).toBeTruthy());
    await act(async () => { fireEvent.click(screen.getByText('不处理（保留原文件）')); });
    await expect(p).resolves.toBeNull();
  });

  it('D4 Esc 关闭 = 取消（resolve null），且只 resolve 一次', async () => {
    mountHost();
    let p: Promise<string | null> | null = null;
    await act(async () => {
      p = choiceDialog({ title: '同名', message: 'x', options: [{ value: 'skip', label: '跳过' }] });
    });
    await waitFor(() => expect(screen.getByRole('dialog')).toBeTruthy());
    await act(async () => {
      window.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape' }));
    });
    await expect(p).resolves.toBeNull();
    // ⛔ 关闭后 choiceCurrent 已清空：再发一次 Esc 不得重复 resolve（否则会污染下一次弹窗）
    await act(async () => {
      window.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape' }));
    });
    expect(screen.queryByRole('dialog')).toBeNull();
  });

  it('D5 danger 选项用危险样式类名（覆盖是破坏性动作，视觉须警示）', async () => {
    mountHost();
    await act(async () => {
      void choiceDialog({
        title: '同名', message: 'x',
        options: [
          { value: 'overwrite', label: '覆盖同名文件', danger: true },
          { value: 'rename', label: '改名并存' },
        ],
      });
    });
    await waitFor(() => expect(screen.getByRole('dialog')).toBeTruthy());
    const dangerBtn = screen.getByText('覆盖同名文件').closest('button');
    const safeBtn = screen.getByText('改名并存').closest('button');
    expect(dangerBtn?.className).toContain('ui-btn-danger');
    expect(safeBtn?.className).not.toContain('ui-btn-danger');
    // 收尾：关掉这个未 resolve 的弹窗，别串到下个用例
    await act(async () => { fireEvent.click(screen.getByText('改名并存')); });
  });
});
