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
import { describe, it, expect, vi, beforeEach } from 'vitest';
import { render, screen, waitFor, act, fireEvent } from '@testing-library/react';
import React from 'react';
import { TaskPanel } from '../panels/TaskPanel';

import { jsonRes, sseResControllable, sseEvent } from './helpers/fetchMock';

// TS-108 M3-2：任务状态面板测试（四种状态徽标 + 失败任务重试按钮 + 重试请求）
if (typeof (globalThis as any).localStorage === 'undefined') {
  (globalThis as any).localStorage = {
    _d: {} as Record<string, string>,
    getItem(k: string) { return this._d[k] ?? null; },
    setItem(k: string, v: string) { this._d[k] = String(v); },
    removeItem(k: string) { delete this._d[k]; },
    clear() { this._d = {}; },
  };
}

const TASKS = [
  { id: 't1', target_agent_name: '文员', task: '整理会议纪要并写入 notes.md', status: 'done', report: { summary: '已整理' } },
  { id: 't2', target_agent_name: '研究员', task: '调研竞品', status: 'running' },
  { id: 't3', target_agent_name: '数据员', task: '清洗数据', status: 'queued' },
  { id: 't4', target_agent_name: '翻译员', task: '翻译文档', status: 'failed', fail_reason: '交卷格式两次校验未通过' },
];

beforeEach(() => {
  vi.restoreAllMocks();
  localStorage.clear();
});

describe('TaskPanel 任务状态面板', () => {
  it('渲染四种状态徽标 + 失败任务有重试按钮 + 摘要展示', async () => {
    const impl: typeof fetch = async (url, init?) => {
      const u = String(url);
      if (u.includes('/tasks')) return jsonRes(TASKS);
      return jsonRes({});
    };
    vi.spyOn(globalThis, 'fetch').mockImplementation(impl);

    render(<TaskPanel projectId="p1" />);

    await waitFor(() => {
      // 状态徽标文字（emoji 已换为 SVG 图标，文字标签不变）
      expect(screen.getByText('完成')).toBeTruthy();
      expect(screen.getByText('进行中')).toBeTruthy();
      expect(screen.getByText('等待中')).toBeTruthy();
      expect(screen.getByText('异常')).toBeTruthy();
    }, { timeout: 3000 });

    // 目标与摘要
    expect(screen.getByText('文员')).toBeTruthy();
    expect(screen.getByText(/已整理/)).toBeTruthy();
    // 失败原因 + 仅失败任务有重试按钮
    expect(screen.getByText(/交卷格式两次校验未通过/)).toBeTruthy();
    const retryBtns = screen.getAllByText('重试');
    expect(retryBtns.length).toBe(1);
  });

  it('点击重试发起 POST 请求并刷新列表', async () => {
    const calls: string[] = [];
    const impl2: typeof fetch = async (url, init?) => {
      const u = String(url);
      calls.push(`${init?.method || 'GET'} ${u}`);
      if (init?.method === 'POST' && u.includes('/retry')) {
        return jsonRes({ new_task_id: 't5', result: { ok: true } });
      }
      if (u.includes('/tasks')) return jsonRes(TASKS);
      return jsonRes({});
    };
    vi.spyOn(globalThis, 'fetch').mockImplementation(impl2);

    render(<TaskPanel projectId="p1" />);

    await waitFor(() => {
      expect(screen.getAllByText('重试').length).toBe(1);
    }, { timeout: 3000 });

    await act(async () => {
      fireEvent.click(screen.getByText('重试'));
    });

    await waitFor(() => {
      expect(calls.some(c => c.startsWith('POST') && c.includes('/tasks/t4/retry'))).toBe(true);
    }, { timeout: 3000 });
    // 重试成功提示出现
    await waitFor(() => {
      expect(screen.getByText(/重试完成：子任务成功交卷/)).toBeTruthy();
    }, { timeout: 3000 });
  });

  it('空列表显示占位文案', async () => {
    vi.spyOn(globalThis, 'fetch').mockImplementation(async () => jsonRes([]));

    render(<TaskPanel projectId="p1" />);
    await waitFor(() => {
      expect(screen.getByText('暂无委派任务')).toBeTruthy();
    }, { timeout: 3000 });
  });
});

// TS-114（3.25）：running 任务停止按钮
describe('TaskPanel 停止按钮（TS-114 3.25）', () => {
  const TASKS_WITH_RUNNING = [
    { id: 't1', target_agent_name: '文员', task: '整理会议纪要', status: 'done', report: { summary: '已整理' } },
    { id: 't2', target_agent_name: '研究员', task: '调研竞品', status: 'running' },
    { id: 't3', target_agent_name: '翻译员', task: '翻译文档', status: 'failed', fail_reason: '交卷格式两次校验未通过' },
  ];

  it('running 任务显示停止按钮（failed/done 不显示）', async () => {
    const impl3: typeof fetch = async (url) => {
      const u = String(url);
      if (u.includes('/tasks')) return jsonRes(TASKS_WITH_RUNNING);
      return jsonRes({});
    };
    vi.spyOn(globalThis, 'fetch').mockImplementation(impl3);

    render(<TaskPanel projectId="p1" />);
    await waitFor(() => {
      expect(screen.getByText('进行中')).toBeTruthy();
    }, { timeout: 3000 });

    const stopBtns = screen.getAllByText('停止');
    expect(stopBtns.length).toBe(1); // 仅 running 任务
    // failed/done 没有停止按钮
    expect(screen.getAllByText('重试').length).toBe(1);
  });

  it('点击停止 → POST /tasks/{id}/stop → 刷新任务列表', async () => {
    const calls: string[] = [];
    let listCalls = 0;
    const impl4: typeof fetch = async (url, init?) => {
      const u = String(url);
      calls.push(`${init?.method || 'GET'} ${u}`);
      if (u.includes('/stop')) {
        return jsonRes({ ok: true, detail: '已请求停止' });
      }
      if (u.includes('/tasks')) {
        listCalls += 1;
        return jsonRes(TASKS_WITH_RUNNING);
      }
      return jsonRes({});
    };
    vi.spyOn(globalThis, 'fetch').mockImplementation(impl4);

    render(<TaskPanel projectId="p1" />);
    await waitFor(() => {
      expect(screen.getAllByText('停止').length).toBe(1);
    }, { timeout: 3000 });
    const before = listCalls;
    fireEvent.click(screen.getByText('停止'));
    await waitFor(() => {
      expect(calls.some(c => c.startsWith('POST') && c.includes('/tasks/t2/stop'))).toBe(true);
      expect(listCalls).toBeGreaterThan(before); // 点击后触发一次刷新
    }, { timeout: 3000 });
  });

  it('停止端点 400（任务已结束）→ 显示停止失败提示', async () => {
    const impl5: typeof fetch = async (url, init?) => {
      const u = String(url);
      if (u.includes('/stop')) {
        return jsonRes({ detail: '任务已结束（done），无需停止' }, 400);
      }
      if (u.includes('/tasks')) {
        return jsonRes(TASKS_WITH_RUNNING);
      }
      return jsonRes({});
    };
    vi.spyOn(globalThis, 'fetch').mockImplementation(impl5);

    render(<TaskPanel projectId="p1" />);
    await waitFor(() => {
      expect(screen.getAllByText('停止').length).toBe(1);
    }, { timeout: 3000 });
    fireEvent.click(screen.getByText('停止'));
    await waitFor(() => {
      expect(screen.getByText(/停止失败/)).toBeTruthy();
    }, { timeout: 3000 });
  });
});

// ══════════════════════════════════════════════════════════════════
// 0.4.20（#15）：委派任务**实时进度**流消费
//
// ⛔ 修的用户可见缺陷：委派跑起来后，面板要等任务整个结束才看得到结果。
//    实测根因比原记录更严重——TaskPanel 原本**连自动轮询都没有**，
//    只在 mount 时拉一次，之后全靠手点"刷新"（旧注释"轮询 8s 之外"是失真的）。
//
// ⛔⛔ 路由顺序陷阱：流端点是 `/tasks/stream`，而列表端点是 `/tasks?limit=30`，
//    两者都含子串 `/tasks`。**必须先匹配 `/tasks/stream`**，否则流请求被 JSON 响应
//    吞掉（`res.body` 为 null → 静默失败 → 每 3s 重连），测试会"看起来通过"
//    却根本没测到流消费。本 describe 内所有 impl 都按此顺序写。
// ══════════════════════════════════════════════════════════════════

const RUNNING_TASKS = [
  { id: 'r1', target_agent_name: '文员', task: '整理证据材料', status: 'running' },
];

describe('TaskPanel #15 委派实时进度流', () => {
  it('S1 订阅流端点 + snapshot 整体替换任务列表', async () => {
    const ctl = sseResControllable();
    const seenUrls: string[] = [];
    let streamSignal: AbortSignal | null = null;
    const impl: typeof fetch = async (url, init?) => {
      const u = String(url);
      seenUrls.push(u);
      if (u.includes('/tasks/stream')) {          // ⛔ 必须先于 '/tasks' 判断
        streamSignal = (init?.signal as AbortSignal) ?? null;
        return ctl.res;
      }
      if (u.includes('/tasks')) return jsonRes([]);
      return jsonRes({});
    };
    vi.spyOn(globalThis, 'fetch').mockImplementation(impl);

    render(<TaskPanel projectId="p1" />);

    await waitFor(() => {
      expect(seenUrls.some(u => u.includes('/tasks/stream'))).toBe(true);
    }, { timeout: 3000 });
    expect(streamSignal).not.toBeNull();

    // 连上后先推 snapshot（后端契约：DB 权威基线）
    await act(async () => {
      ctl.push(sseEvent('snapshot', { tasks: RUNNING_TASKS }));
    });
    await waitFor(() => {
      expect(screen.getByText('文员')).toBeTruthy();
      expect(screen.getByText('进行中')).toBeTruthy();
    }, { timeout: 3000 });

    await act(async () => { ctl.close(); });
  });

  it('S2 tool_call → 显示「正在调用 read_file」；tool_result → 去掉该前缀', async () => {
    const ctl = sseResControllable();
    const impl: typeof fetch = async (url) => {
      const u = String(url);
      if (u.includes('/tasks/stream')) return ctl.res;
      if (u.includes('/tasks')) return jsonRes(RUNNING_TASKS);
      return jsonRes({});
    };
    vi.spyOn(globalThis, 'fetch').mockImplementation(impl);

    render(<TaskPanel projectId="p1" />);
    await act(async () => {
      ctl.push(sseEvent('snapshot', { tasks: RUNNING_TASKS }));
    });

    await act(async () => {
      ctl.push(sseEvent('tool_call', { task_id: 'r1', name: 'read_file', seq: 1 }));
    });
    await waitFor(() => {
      expect(screen.getByTestId('live-tool').textContent).toContain('正在调用');
      expect(screen.getByTestId('live-tool').textContent).toContain('read_file');
    }, { timeout: 3000 });

    // 工具回来 → 不再显示"正在调用"（转圈结束，改显结果图标）
    await act(async () => {
      ctl.push(sseEvent('tool_result', { task_id: 'r1', name: 'read_file', ok: true, seq: 2 }));
    });
    await waitFor(() => {
      expect(screen.getByTestId('live-tool').textContent).not.toContain('正在调用');
      expect(screen.getByTestId('live-tool').textContent).toContain('read_file');
    }, { timeout: 3000 });

    await act(async () => { ctl.close(); });
  });

  it('S3 progress → 显示轮次与已生成字数', async () => {
    const ctl = sseResControllable();
    const impl: typeof fetch = async (url) => {
      const u = String(url);
      if (u.includes('/tasks/stream')) return ctl.res;
      if (u.includes('/tasks')) return jsonRes(RUNNING_TASKS);
      return jsonRes({});
    };
    vi.spyOn(globalThis, 'fetch').mockImplementation(impl);

    render(<TaskPanel projectId="p1" />);
    await act(async () => {
      ctl.push(sseEvent('snapshot', { tasks: RUNNING_TASKS }));
    });
    await act(async () => {
      ctl.push(sseEvent('progress', { task_id: 'r1', step: 3, max: 200, chars: 1847, seq: 1 }));
    });
    await waitFor(() => {
      expect(screen.getByTestId('live-step').textContent).toContain('第 3/200 轮');
      expect(screen.getByTestId('live-chars').textContent).toContain('已生成 1847 字');
    }, { timeout: 3000 });

    await act(async () => { ctl.close(); });
  });

  it('S4 ⛔ 卸载即 abort，且卸载后到达的事件不再产生副作用（无泄漏）', async () => {
    const ctl = sseResControllable();
    let streamSignal: AbortSignal | null = null;
    let listCalls = 0;                    // ⛔ 可观测副作用计数器
    const impl: typeof fetch = async (url, init?) => {
      const u = String(url);
      if (u.includes('/tasks/stream')) {
        streamSignal = (init?.signal as AbortSignal) ?? null;
        return ctl.res;
      }
      if (u.includes('/tasks')) { listCalls++; return jsonRes(RUNNING_TASKS); }
      return jsonRes({});
    };
    vi.spyOn(globalThis, 'fetch').mockImplementation(impl);

    const { unmount } = render(<TaskPanel projectId="p1" />);
    await waitFor(() => { expect(streamSignal).not.toBeNull(); }, { timeout: 3000 });
    await act(async () => {
      ctl.push(sseEvent('snapshot', { tasks: RUNNING_TASKS }));
    });

    unmount();

    // ⛔ 核心断言一：卸载时必须 abort（否则 reader 永远挂着 = 连接与内存泄漏）
    expect((streamSignal as unknown as AbortSignal).aborted).toBe(true);

    // ⛔ 核心断言二：卸载后到达的事件**不得产生任何副作用**。
    //
    // ⛔⛔ 首轮这里写的是"断言 console.error 里没有 unmounted/state update 告警"——
    //    **那是空转断言**：React 18 已移除"Can't perform a React state update on an
    //    unmounted component"警告，撤掉 `if (cancelled) return` 守卫后测试照样全绿
    //    （变异 F2 实测未被抓住）。断言必须锚定**可观测行为**，不是"某句告警没出现"。
    //
    // ✅ 可观测点：`status=done` 与 `task_end` 都会触发 `loadTasks(true)` → 一次真实 fetch。
    //    守卫在位 → 事件被丢弃 → listCalls 不变；守卫被撤 → 卸载后仍发请求。
    //    这同时覆盖了"卸载后不再 setState"（同一条 return 守卫管着两者）。
    const before = listCalls;
    await act(async () => {
      ctl.push(sseEvent('status', { task_id: 'r1', state: 'done', seq: 9 }));
      ctl.push(sseEvent('task_end', { task_id: 'r1', seq: 10 }));
      ctl.push(sseEvent('gap', { from: 3, oldest_available: 90, seq: 11 }));
      ctl.push(sseEvent('tool_call', { task_id: 'r1', name: 'write_file', seq: 12 }));
    });
    expect(listCalls).toBe(before);       // ⛔ 卸载后零新增请求

    await act(async () => { ctl.close(); });
  });

  it('S5 终态 status=done → 静默重拉 DB，渲染 report.summary', async () => {
    const ctl = sseResControllable();
    const DONE_TASKS = [
      { id: 'r1', target_agent_name: '文员', task: '整理证据材料', status: 'done',
        report: { summary: '已整理 12 份证据并生成清单' } },
    ];
    let listCalls = 0;
    const impl: typeof fetch = async (url) => {
      const u = String(url);
      if (u.includes('/tasks/stream')) return ctl.res;
      if (u.includes('/tasks')) { listCalls++; return jsonRes(listCalls === 1 ? RUNNING_TASKS : DONE_TASKS); }
      return jsonRes({});
    };
    vi.spyOn(globalThis, 'fetch').mockImplementation(impl);

    render(<TaskPanel projectId="p1" />);
    await waitFor(() => { expect(listCalls).toBeGreaterThanOrEqual(1); }, { timeout: 3000 });
    await act(async () => {
      ctl.push(sseEvent('snapshot', { tasks: RUNNING_TASKS }));
    });
    await waitFor(() => {
      expect(screen.getByText('进行中')).toBeTruthy();
    }, { timeout: 3000 });

    // 流只给状态信号，终态详情（summary）以 DB 为准 → 应触发静默重拉
    await act(async () => {
      ctl.push(sseEvent('status', { task_id: 'r1', state: 'done', seq: 5 }));
    });
    await waitFor(() => {
      expect(listCalls).toBeGreaterThanOrEqual(2);
      expect(screen.getByText(/已整理 12 份证据/)).toBeTruthy();
      expect(screen.getByText('完成')).toBeTruthy();
    }, { timeout: 3000 });

    await act(async () => { ctl.close(); });
  });

  it('S6 未知事件与 gap 不崩，gap 触发重拉快照对齐', async () => {
    const ctl = sseResControllable();
    let listCalls = 0;
    const impl: typeof fetch = async (url) => {
      const u = String(url);
      if (u.includes('/tasks/stream')) return ctl.res;
      if (u.includes('/tasks')) { listCalls++; return jsonRes(RUNNING_TASKS); }
      return jsonRes({});
    };
    vi.spyOn(globalThis, 'fetch').mockImplementation(impl);

    render(<TaskPanel projectId="p1" />);
    await waitFor(() => { expect(listCalls).toBeGreaterThanOrEqual(1); }, { timeout: 3000 });

    const before = listCalls;
    await act(async () => {
      ctl.push(sseEvent('some_future_event', { task_id: 'r1', foo: 1 }));   // 未知事件须忽略
      ctl.push(sseEvent('gap', { from: 3, oldest_available: 90 }));          // 断档须重拉
    });
    await waitFor(() => {
      expect(listCalls).toBeGreaterThan(before);
    }, { timeout: 3000 });
    expect(screen.getByText('文员')).toBeTruthy();

    await act(async () => { ctl.close(); });
  });

  it('S7 流请求失败 → 不弹错误条（手动刷新仍可用），静默退避', async () => {
    const impl: typeof fetch = async (url) => {
      const u = String(url);
      if (u.includes('/tasks/stream')) return jsonRes({ detail: 'boom' }, 500);
      if (u.includes('/tasks')) return jsonRes(RUNNING_TASKS);
      return jsonRes({});
    };
    vi.spyOn(globalThis, 'fetch').mockImplementation(impl);

    render(<TaskPanel projectId="p1" />);
    await waitFor(() => {
      expect(screen.getByText('文员')).toBeTruthy();
    }, { timeout: 3000 });
    // ⛔ 流失败不得污染列表加载的错误条（否则用户会以为任务列表也坏了）
    expect(screen.queryByText(/加载失败/)).toBeNull();
  });

  it('S8 实时流连接指示器：连上=绿点，未连上=灰点（streamOn 不再是死状态）', async () => {
    // ⛔ 为什么单独立这条用例：`streamOn` 原本只被 set 从未被读（死状态），
    //    0.4.20 接入标题行指示器后才有了渲染职责。没有断言锁定它，
    //    将来谁把指示器删了、或把 setStreamOn 写错位置，测试都不会响。
    //    判据用**颜色**而非文案：绿=colors.ok(#34C759) 表示实时流在连，灰=兜底手动刷新。
    const ctl = sseResControllable();
    const impl: typeof fetch = async (url) => {
      const u = String(url);
      if (u.includes('/tasks/stream')) return ctl.res;
      if (u.includes('/tasks')) return jsonRes(RUNNING_TASKS);
      return jsonRes({});
    };
    vi.spyOn(globalThis, 'fetch').mockImplementation(impl);

    render(<TaskPanel projectId="p1" />);

    // 连上后指示器变绿
    await waitFor(() => {
      const dot = screen.getByTestId('stream-indicator');
      expect(String(dot.getAttribute('title'))).toContain('已连接');
      expect(String((dot as HTMLElement).style.background)).toContain('rgb(52, 199, 89)');
    }, { timeout: 3000 });

    await act(async () => { ctl.close(); });

    // 流关闭后退回灰点（告知用户需手动刷新），但**列表数据保持不动**
    await waitFor(() => {
      const dot = screen.getByTestId('stream-indicator');
      expect(String(dot.getAttribute('title'))).toContain('未连接');
    }, { timeout: 3000 });
    expect(screen.getByText('文员')).toBeTruthy();
  });
});
