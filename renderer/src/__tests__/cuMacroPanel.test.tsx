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
 * 0.4.32（CU 三期 P3）：任务宏面板 + 元素定位开关 测试。
 *
 * 契约锚点（后端 sidecar/computer_use/cu_macro.py + app.py 2379-2439，mock 必须同构）：
 *   GET  /api/cu-macros                → {ok, macros:[{id,name,created_at,steps:数}], recording}
 *   POST /api/cu-macros/record/start   → {ok,name}；422 {detail}
 *   POST /api/cu-macros/record/stop    → {ok,macro}
 *   POST /api/cu-macros/{id}/replay    → {ok,run_id}；422 回放忙
 *   GET  /api/cu-macros/replays/{rid}  → {ok,run:{status,completed,total,failed_seq,error,steps[{seq,action,method,ok,error}]}}
 *   DELETE /api/cu-macros/{id}         → {deleted:true}
 * 命中率口径（计划 P3 拍板）：回放口径——element vs pixel_fallback 计数自 run.steps，
 *   后端审计 actions.jsonl 无读取端点，故 UI 必须如实标注「回放口径」。
 */
import { describe, it, expect, vi, beforeEach } from 'vitest';
import { render, screen, waitFor, act, fireEvent } from '@testing-library/react';
import React from 'react';
import { CuMacroPanel } from '../panels/CuMacroPanel';
import { SettingsPanel } from '../panels/SettingsPanel';
import { installFetchMock, routeJson, jsonRes, type FetchRoute } from './helpers/fetchMock';
import { emit, __resetEventsForTest } from '../events';
import { APP_RESOURCE_CHANGED } from '../appEvents';

const MACROS = [
  { id: 'cu-1', name: '整理下载目录', created_at: '2026-09-18 10:00:00', steps: 3 },
  { id: 'cu-2', name: '晨间例行', created_at: '2026-09-18 09:00:00', steps: 5 },
];

beforeEach(() => {
  vi.restoreAllMocks();
  __resetEventsForTest();
  // confirmDialog 是模块级单例、渲染进 document.body——清掉上个用例的残留弹窗
  document.querySelectorAll('[role="dialog"]').forEach(n => n.remove());
});

describe('0.4.32 P3 任务宏面板', () => {
  it('宏列表渲染：名称 / 创建时间 / 步骤数；命中率零样本显示口径与暂无样本', async () => {
    installFetchMock([
      routeJson('/api/cu-macros', { ok: true, macros: MACROS, recording: false }),
    ]);
    const { unmount } = render(<CuMacroPanel />);
    await waitFor(() => {
      expect(screen.getByText('整理下载目录')).toBeTruthy();
      expect(screen.getByText('晨间例行')).toBeTruthy();
    });
    expect(screen.getByText(/2026-09-18 10:00:00 · 3 步/)).toBeTruthy();
    expect(screen.getByText(/2026-09-18 09:00:00 · 5 步/)).toBeTruthy();
    // 命中率：未回放过 → 标注口径 + 暂无样本（不得假装有全程命中率数据）
    expect(screen.getByText(/元素定位命中率（回放口径）/)).toBeTruthy();
    expect(screen.getByText(/暂无回放样本/)).toBeTruthy();
    unmount();
  });

  it('录制起停：输入名称→开始录制（POST body 断言）→录制中状态→停止并保存（POST 断言）', async () => {
    let recording = false;
    const listRoute: FetchRoute = (url) =>
      url.endsWith('/api/cu-macros') ? jsonRes({ ok: true, macros: MACROS, recording }) : null;
    const h = installFetchMock([
      routeJson('/api/cu-macros/record/start', { ok: true, name: '晚间备份' }),
      routeJson('/api/cu-macros/record/stop', {
        ok: true,
        macro: { id: 'cu-3', name: '晚间备份', created_at: '2026-09-18 11:00:00', steps: [{ seq: 1 }] },
      }),
      listRoute,
    ]);
    const { unmount } = render(<CuMacroPanel />);
    await waitFor(() => expect(screen.getByText('整理下载目录')).toBeTruthy());

    // 名称为空时按钮禁用（防 422 的前端第一道）
    const startBtn = screen.getByText('开始录制') as HTMLButtonElement;
    expect(startBtn.disabled).toBe(true);
    fireEvent.change(screen.getByPlaceholderText(/宏名称/), { target: { value: '晚间备份' } });
    expect(startBtn.disabled).toBe(false);

    await act(async () => { startBtn.click(); });
    expect(h.lastBodyOf('/api/cu-macros/record/start')).toEqual({ name: '晚间备份' });
    await waitFor(() => expect(screen.getByText(/正在录制「晚间备份」/)).toBeTruthy());
    // 录制中：输入区收起，露出停止按钮
    expect(screen.queryByPlaceholderText(/宏名称/)).toBeNull();

    await act(async () => { (screen.getByText('停止并保存') as HTMLButtonElement).click(); });
    expect(h.countOf('/api/cu-macros/record/stop')).toBe(1);
    await waitFor(() => expect(screen.queryByText(/正在录制/)).toBeNull());
    // 停止后重拉列表（GET 次数 ≥ 2：挂载 1 + stop 后 refresh 1）
    expect(h.countOf('/api/cu-macros')).toBeGreaterThanOrEqual(2);
    unmount();
  });

  it('录制冲突 422：后端 detail 如实上屏，不静默', async () => {
    installFetchMock([
      routeJson('/api/cu-macros/record/start',
        { detail: 'already_recording: 正在录制宏「X」，请先停止当前录制' }, 422),
      routeJson('/api/cu-macros', { ok: true, macros: [], recording: false }),
    ]);
    const { unmount } = render(<CuMacroPanel />);
    await waitFor(() => expect(screen.getByText(/暂无宏/)).toBeTruthy());
    fireEvent.change(screen.getByPlaceholderText(/宏名称/), { target: { value: '重复' } });
    await act(async () => { (screen.getByText('开始录制') as HTMLButtonElement).click(); });
    await waitFor(() => expect(screen.getByText(/开始录制失败: already_recording/)).toBeTruthy());
    unmount();
  });

  it('回放轮询进度：0/total 本地态 → 轮询推进 → 完成；命中率按回放口径统计 element vs pixel_fallback', async () => {
    let statusCalls = 0;
    const statusRoute: FetchRoute = (url) => {
      if (!url.includes('/api/cu-macros/replays/run-1')) return null;
      statusCalls++;
      const run = statusCalls === 1
        ? { run_id: 'run-1', macro_id: 'cu-1', macro_name: '整理下载目录', status: 'running',
            total: 2, completed: 1, failed_seq: null, error: '',
            steps: [{ seq: 1, action: 'click', method: 'element', ok: true }] }
        : { run_id: 'run-1', macro_id: 'cu-1', macro_name: '整理下载目录', status: 'done',
            total: 2, completed: 2, failed_seq: null, error: '',
            steps: [{ seq: 1, action: 'click', method: 'element', ok: true },
                    { seq: 2, action: 'click', method: 'pixel_fallback', ok: true }] };
      return jsonRes({ ok: true, run });
    };
    const h = installFetchMock([
      statusRoute,
      routeJson('/api/cu-macros/cu-1/replay', { ok: true, run_id: 'run-1' }),
      routeJson('/api/cu-macros', { ok: true, macros: [MACROS[0]], recording: false }),
    ]);
    const { unmount } = render(<CuMacroPanel pollMs={20} />);
    await waitFor(() => expect(screen.getByText('整理下载目录')).toBeTruthy());

    await act(async () => { (screen.getByText('回放') as HTMLButtonElement).click(); });
    expect(h.countOf('/api/cu-macros/cu-1/replay')).toBe(1);
    // 触发后本地立即进入 running 态（回放块出现；0/2 精确中间态随轮询间隔流逝，不断言）
    expect(screen.getByText('回放「整理下载目录」')).toBeTruthy();

    // 轮询推进到 done（done 状态只能来自 GET /replays/run-1 → 证明轮询生效）
    await waitFor(() => expect(screen.getByText(/回放完成：2\/2 步成功/)).toBeTruthy(), { timeout: 3000 });
    expect(statusCalls).toBeGreaterThan(0);
    // 命中率：element 1 / pixel_fallback 1 → 50%，样本 2，口径标注在
    expect(screen.getByText(/50%（element 1 \/ pixel_fallback 1，样本 2）/)).toBeTruthy();
    expect(screen.getByText(/元素定位命中率（回放口径）/)).toBeTruthy();
    // 最后一步的命中方式徽标
    expect(screen.getByText('像素回落')).toBeTruthy();
    unmount();
  });

  it('回放失败中止：显示失败步骤号与后端错误，命中方式徽标含中止', async () => {
    const statusRoute: FetchRoute = (url) =>
      url.includes('/api/cu-macros/replays/run-9')
        ? jsonRes({ ok: true, run: {
            run_id: 'run-9', macro_id: 'cu-1', macro_name: '整理下载目录', status: 'error',
            total: 3, completed: 1, failed_seq: 2,
            error: '第 2 步（click）失败：目标应用未启动。已中止，后续步骤未执行。',
            steps: [{ seq: 1, action: 'click', method: 'element', ok: true },
                    { seq: 2, action: 'click', method: 'abort', ok: false, error: '目标应用未启动' }] } })
        : null;
    installFetchMock([
      statusRoute,
      routeJson('/api/cu-macros/cu-1/replay', { ok: true, run_id: 'run-9' }),
      routeJson('/api/cu-macros', { ok: true, macros: [MACROS[0]], recording: false }),
    ]);
    const { unmount } = render(<CuMacroPanel pollMs={20} />);
    await waitFor(() => expect(screen.getByText('整理下载目录')).toBeTruthy());
    await act(async () => { (screen.getByText('回放') as HTMLButtonElement).click(); });
    await waitFor(() => expect(screen.getByText(/回放中止：第 2 步失败/)).toBeTruthy(), { timeout: 3000 });
    expect(screen.getByText(/目标应用未启动。已中止/)).toBeTruthy();
    expect(screen.getByText('中止')).toBeTruthy();          // method=abort 徽标
    unmount();
  });

  it('删除：confirmDialog 确认后才 DELETE；取消则不发请求', async () => {
    const h = installFetchMock([
      (url, init) => (url.includes('/api/cu-macros/cu-1') && init?.method === 'DELETE')
        ? jsonRes({ deleted: true }) : null,
      routeJson('/api/cu-macros', { ok: true, macros: [MACROS[0]], recording: false }),
    ]);
    const { unmount } = render(<CuMacroPanel />);
    await waitFor(() => expect(screen.getByText('整理下载目录')).toBeTruthy());
    const delBtn = document.querySelector('button[data-tip="删除宏"]') as HTMLButtonElement;
    expect(delBtn).toBeTruthy();

    // 先走取消路径：弹窗出现 → 取消 → 不得发 DELETE
    await act(async () => { delBtn.click(); });
    const cancelBtn = await screen.findByRole('button', { name: '取消' });
    await act(async () => { cancelBtn.click(); });
    expect(h.calls.some(c => c.method === 'DELETE')).toBe(false);

    // 再走确认路径
    await act(async () => { delBtn.click(); });
    const confirmBtn = await screen.findByRole('button', { name: '删除' });
    await act(async () => { confirmBtn.click(); });
    expect(h.calls.some(c => c.method === 'DELETE' && c.url.includes('/api/cu-macros/cu-1'))).toBe(true);
    unmount();
  });

  it('SSE：cu_macro create/delete 重拉列表；replay_step 步骤事件不重拉（进度走轮询）', async () => {
    const h = installFetchMock([
      routeJson('/api/cu-macros', { ok: true, macros: [], recording: false }),
    ]);
    const { unmount } = render(<CuMacroPanel />);
    await waitFor(() => expect(h.countOf('/api/cu-macros')).toBe(1));

    act(() => { emit(APP_RESOURCE_CHANGED, { resource: 'cu_macro', action: 'create' }); });
    await waitFor(() => expect(h.countOf('/api/cu-macros')).toBe(2));
    act(() => { emit(APP_RESOURCE_CHANGED, { resource: 'cu_macro', action: 'delete' }); });
    await waitFor(() => expect(h.countOf('/api/cu-macros')).toBe(3));

    // replay_step 高频步骤事件刻意不触发重拉（否则回放期间请求爆炸）
    act(() => { emit(APP_RESOURCE_CHANGED, { resource: 'cu_macro', action: 'replay_step', run_id: 'r', seq: 1 }); });
    await new Promise(r => setTimeout(r, 80));
    expect(h.countOf('/api/cu-macros')).toBe(3);
    unmount();
  });
});

describe('0.4.32 P3 元素定位开关（设置页 CU 区）', () => {
  const CFG = {
    ollama_base_url: 'http://localhost:11434', proxy_http_port: 7890, proxy_socks_port: 7891,
    data_root: '~/.subagent', default_model: 'qwen3.8', plugin_repos: [], egress_proxy_required: [],
    sidecar_host: '127.0.0.1', sidecar_port: 8765, vite_port: 5173, network_switch: 'auto',
    max_tool_rounds: 200, compact_archive_dir: '', allow_auto_compact: false, compact_keep_recent: 10,
    computer_use_enabled: true, computer_use_confirm_each: true, computer_use_app_whitelist: [],
    cu_element_locate_enabled: false,
  };

  it('开关读 cfg 初值（false→未勾选），点击即 PUT cu_element_locate_enabled:true（勾选即存）', async () => {
    const h = installFetchMock([
      (url, init) => (url.includes('/api/config') && init?.method === 'PUT')
        ? jsonRes({ ...CFG, cu_element_locate_enabled: true }) : null,
      routeJson('/api/config', CFG),
      routeJson('/inference/models', []),
      routeJson('/computer-use/capabilities', { ok: true, problems: [], facts: {} }),
      routeJson('/api/cu-macros', { ok: true, macros: [], recording: false }),
    ]);
    const { unmount } = render(<SettingsPanel embedded />);
    const toggle = await screen.findByLabelText('元素定位（命中测试校正点击坐标）') as HTMLInputElement;
    expect(toggle.checked).toBe(false);                    // 读：cfg 初值 false

    await act(async () => { fireEvent.click(toggle); });
    // 写：单键 PATCH 即存（与 computer_use_confirm_each 同一风格），不连带其它字段
    expect(h.lastBodyOf('/api/config')).toEqual({ cu_element_locate_enabled: true });
    await waitFor(() => expect(toggle.checked).toBe(true)); // PUT 返回新配置 → 勾选态更新
    unmount();
  });

  it('开关缺省（配置无该键）→ 按后端默认 true 显示勾选', async () => {
    const cfgNoKey = { ...CFG } as Record<string, unknown>;
    delete cfgNoKey.cu_element_locate_enabled;
    installFetchMock([
      routeJson('/api/config', cfgNoKey),
      routeJson('/inference/models', []),
      routeJson('/computer-use/capabilities', { ok: true, problems: [], facts: {} }),
      routeJson('/api/cu-macros', { ok: true, macros: [], recording: false }),
    ]);
    const { unmount } = render(<SettingsPanel embedded />);
    const toggle = await screen.findByLabelText('元素定位（命中测试校正点击坐标）') as HTMLInputElement;
    expect(toggle.checked).toBe(true);
    unmount();
  });
});
