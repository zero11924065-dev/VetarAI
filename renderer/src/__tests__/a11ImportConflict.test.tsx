/*
 * VetarAI - Local-first multi-agent orchestration application
 * Copyright (C) 2026 zero11924065-dev
 * GPL-3.0-or-later（见仓库 LICENSE）
 */
/**
 * A11（0.4.22）专项：知识仓库「导入文件」遇同名冲突时的**两段式重传**编排。
 *
 * 用户 2026-09-12 拍板：同名不再自动改名，而是**弹窗问我**（覆盖 / 改名并存 / 跳过）。
 * 前端因此分两趟调用后端：
 *   第一趟 on_conflict='ask'  → 不冲突的正常导入，冲突的**原样留着**并列在 conflicts 返回；
 *   弹窗让用户选 → 第二趟 on_conflict=<用户选的> 且**只重传冲突的那几个文件**。
 *
 * ⛔ 这里锁的是最容易写错的两点（本套件开发时都真错过一次）：
 *   1. 第二趟**绝不能重传已成功的文件**（否则同一文件被导入两次 / 生成 _1 _2 副本）；
 *   2. 计数是两趟**相加**且不得重复计（曾写过 `choice==='skip' ? 0 : d.skipped` 再加一遍，
 *      导致选"跳过"时冲突文件被计入两次）。
 */
import { describe, it, expect, vi, beforeEach } from 'vitest';
import { render, screen, waitFor, act, fireEvent } from '@testing-library/react';
import React from 'react';
import { WarehouseManager } from '../panels/WarehouseManager';
import { choiceDialog } from '../Dialog';
import { jsonRes } from './helpers/fetchMock';

// ⛔ 只 mock 弹窗（真实渲染会挂在 body 上、需额外点击编排）；用 importActual 保留其余导出，
// 避免 Dialog.tsx 的 `export { Icon }` 被抹掉后其他模块拿不到。
vi.mock('../Dialog', async (importActual) => {
  const actual = await importActual<typeof import('../Dialog')>();
  return { ...actual, choiceDialog: vi.fn() };
});

const GROUPS = [
  { scope: 'global', project_id: null, project_name: '全局知识', count: 3, dir: '/data/knowledge/global' },
];

// 两趟 import-files 的可控响应
const ASK_RESULT = {
  imported: 1, failed: 0, skipped: 0,
  conflicts: ['报告.docx'],
  details: [{ name: '新文件.txt', status: 'imported' },
            { name: '报告.docx', status: 'conflict' }],
};
const RETRY_RESULT = {
  imported: 1, failed: 0, skipped: 0, conflicts: [],
  details: [{ name: '报告_1.docx', status: 'imported', conflict_resolved: 'rename' }],
};

let importCalls: Array<{ body: any }> = [];

function mockBackend() {
  importCalls = [];
  const impl: typeof fetch = async (input, init?) => {
    const u = String(typeof input === 'string' ? input : (input as any).url);
    if (u.includes('/knowledge/import-files')) {
      const body = JSON.parse(String(init?.body || '{}'));
      importCalls.push({ body });
      // 第一趟 ask 返回冲突；后续趟返回"已按策略处理完"
      return jsonRes(body.on_conflict === 'ask' ? ASK_RESULT : RETRY_RESULT);
    }
    if (u.includes('/knowledge/groups')) return jsonRes(GROUPS);
    if (u.includes('/knowledge/embedding-status')) return jsonRes({ available: false, entries_total: 0, entries_embedded: 0 });
    return jsonRes({});
  };
  vi.spyOn(globalThis, 'fetch').mockImplementation(impl);
}

function mockFilePicker(files: string[]) {
  (window as any).subagent = { chooseInputFile: vi.fn(async () => files) };
}

/** 渲染面板 → 等分组出现 → 点「导入文件」→ 等编排完成。 */
async function runImport(files: string[], choice: string | null) {
  (choiceDialog as any).mockResolvedValue(choice);
  mockFilePicker(files);
  render(<WarehouseManager />);
  await waitFor(() => expect(screen.getByText('全局知识')).toBeTruthy(), { timeout: 3000 });
  await act(async () => {
    fireEvent.click(screen.getByText('导入文件'));
  });
  // 等两趟 fetch + refresh 落地
  await act(async () => { await new Promise(r => setTimeout(r, 60)); });
}

beforeEach(() => {
  vi.restoreAllMocks();
  // ⛔ restoreAllMocks 只还原 vi.spyOn 建的桩，**不清** vi.mock 工厂里 vi.fn() 的调用记录
  //    → choiceDialog 的计数会跨用例累积（首轮 C6/C7 因此报"called 6 times"）。
  //    clearAllMocks 单独清计数，让每个用例都从 0 开始。
  vi.clearAllMocks();
  importCalls = [];
  delete (window as any).subagent;
});

describe('A11 同名冲突：两段式重传编排', () => {
  it('C1 第一趟用 ask 且带上全部选中文件', async () => {
    mockBackend();
    await runImport(['/桌面/报告.docx', '/桌面/新文件.txt'], 'rename');
    expect(importCalls.length).toBe(2);
    expect(importCalls[0].body.on_conflict).toBe('ask');
    expect(importCalls[0].body.paths).toEqual(['/桌面/报告.docx', '/桌面/新文件.txt']);
  });

  it('C2 ⛔ 第二趟只重传冲突文件（绝不重传已成功的）', async () => {
    mockBackend();
    await runImport(['/桌面/报告.docx', '/桌面/新文件.txt'], 'rename');
    expect(importCalls[1].body.on_conflict).toBe('rename');
    // ⛔ 核心：只含冲突的 报告.docx，不含第一趟已成功导入的 新文件.txt
    expect(importCalls[1].body.paths).toEqual(['/桌面/报告.docx']);
  });

  it('C3 计数两趟相加且不重复计（导入 2 个 = 1+1）', async () => {
    mockBackend();
    await runImport(['/桌面/报告.docx', '/桌面/新文件.txt'], 'rename');
    const info = screen.getByText(/导入 2 个/);
    expect(info).toBeTruthy();
    // ⛔ 不得出现"导入 3 个"这类重复计数
    expect(screen.queryByText(/导入 3 个/)).toBeNull();
  });

  it('C4 用户选「覆盖」→ 第二趟 on_conflict=overwrite', async () => {
    mockBackend();
    await runImport(['/桌面/报告.docx'], 'overwrite');
    expect(importCalls[1].body.on_conflict).toBe('overwrite');
  });

  it('C5 ⛔ 用户选「跳过」→ 第二趟 on_conflict=skip，且冲突文件只计一次', async () => {
    mockBackend();
    await runImport(['/桌面/报告.docx'], 'skip');
    expect(importCalls[1].body.on_conflict).toBe('skip');
    // 第二趟后端返回 skipped=0（skip 策略下后端计入 skipped）——这里用 RETRY_RESULT，
    // 故面板汇总应体现第一趟 skipped=0 + 第二趟 skipped=0；关键是**不得**再额外加一次
    // conflicts.length（旧实现的重复计数 bug 点）。
    expect(screen.queryByText(/跳过 2 个/)).toBeNull();
  });

  it('C6 ⛔ 用户取消弹窗 → 不发第二趟，冲突文件如实计入跳过', async () => {
    mockBackend();
    await runImport(['/桌面/报告.docx', '/桌面/新文件.txt'], null);
    expect(importCalls.length).toBe(1);          // 只有 ask 那一趟
    expect(choiceDialog).toHaveBeenCalledTimes(1);
    // 冲突的 1 个计入跳过；第一趟已成功的 1 个仍如实显示
    expect(screen.getByText(/导入 1 个/)).toBeTruthy();
    expect(screen.getByText(/跳过 1 个/)).toBeTruthy();
  });

  it('C7 无同名冲突 → 不弹窗，只发一趟 ask', async () => {
    importCalls = [];
    const impl: typeof fetch = async (input, init?) => {
      const u = String(typeof input === 'string' ? input : (input as any).url);
      if (u.includes('/knowledge/import-files')) {
        importCalls.push({ body: JSON.parse(String(init?.body || '{}')) });
        return jsonRes({ imported: 2, failed: 0, skipped: 0, conflicts: [], details: [] });
      }
      if (u.includes('/knowledge/groups')) return jsonRes(GROUPS);
      if (u.includes('/knowledge/embedding-status')) return jsonRes({ available: false, entries_total: 0, entries_embedded: 0 });
      return jsonRes({});
    };
    vi.spyOn(globalThis, 'fetch').mockImplementation(impl);

    await runImport(['/桌面/a.txt', '/桌面/b.txt'], 'rename');
    expect(importCalls.length).toBe(1);          // ⛔ 无冲突不该有第二趟
    expect(choiceDialog).not.toHaveBeenCalled(); // 不打扰用户
    expect(screen.getByText(/导入 2 个/)).toBeTruthy();
  });

  it('C8 弹窗文案含冲突文件名与数量（用户能看清在问什么）', async () => {
    mockBackend();
    await runImport(['/桌面/报告.docx'], 'rename');
    const opts = (choiceDialog as any).mock.calls[0][0];
    expect(String(opts.message)).toContain('报告.docx');
    expect(opts.options.map((o: any) => o.value)).toEqual(['overwrite', 'rename', 'skip']);
    // ⛔ 必须明示不动用户原始文件（这是用户敢点"覆盖"的前提）
    expect(String(opts.message)).toContain('原始文件');
  });
});
