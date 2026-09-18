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
 *
 * 0.4.33（插单实测修复批 F2，空宏防护）契约增量（后端并行实现，字段钉死不得改名）：
 *   GET  /api/cu-macros                → 新增 recording_steps:int（未录制为 0）
 *   POST /api/cu-macros/record/stop    → 0 步：HTTP 200 {ok:true, saved:false, steps:0, message:"未捕获到任何动作，宏未保存"}
 *                                        有步骤：{ok:true, saved:true, macro:{...}}
 *   POST /api/cu-macros/{id}/replay    → 空宏 422 {detail:"宏没有可回放的步骤"}
 *
 * R4（用户手动录制模式）契约增量（后端并行实现，字段钉死不得改名）：
 *   POST /api/cu-macros/record/start   → body 增加 mode:"agent"(默认)|"user"；user 未授权 403 {detail:"input_monitoring_not_granted..."}
 *   GET  /api/cu-macros                → 新增 recording_mode: null|"agent"|"user"
 *   GET  /api/cu-macros/user-record/permission         → {ok:true, granted:bool}
 *   POST /api/cu-macros/user-record/permission/request → {ok:true, granted:bool}
 *   互斥 409：录制中 replay / replay 中 user start / 已在录时 start
 */
import { describe, it, expect, vi, beforeEach } from 'vitest';
import { render, screen, waitFor, act, fireEvent } from '@testing-library/react';
import React from 'react';
import { CuMacroPanel } from '../panels/CuMacroPanel';
import { SettingsPanel } from '../panels/SettingsPanel';
import { installFetchMock, routeJson, jsonRes, type FetchRoute } from './helpers/fetchMock';
import { styleColorIs } from './helpers/styleAssert';
import { colors } from '../theme';
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
    const startBtn = screen.getByText('录制 Agent 操作') as HTMLButtonElement;
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
    await act(async () => { (screen.getByText('录制 Agent 操作') as HTMLButtonElement).click(); });
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

describe('0.4.33 F2 宏面板空宏防护', () => {
  /** 只数 GET /api/cu-macros（countOf 是 includes 匹配，会连 record/stop 的 POST 一起数进去）。 */
  const getCount = (h: { calls: Array<{ method: string; url: string }> }) =>
    h.calls.filter(c => c.method === 'GET' && c.url.endsWith('/api/cu-macros')).length;

  it('录制中实时步骤数：轮询显示「已捕获 N 步」且随 recording_steps 递增', async () => {
    let captured = 0;
    const listRoute: FetchRoute = (url) =>
      url.endsWith('/api/cu-macros')
        ? jsonRes({ ok: true, macros: [], recording: false, recording_steps: captured }) : null;
    installFetchMock([
      routeJson('/api/cu-macros/record/start', { ok: true, name: '实时计数' }),
      listRoute,
    ]);
    const { unmount } = render(<CuMacroPanel pollMs={20} />);
    await waitFor(() => expect(screen.getByText(/暂无宏/)).toBeTruthy());

    fireEvent.change(screen.getByPlaceholderText(/宏名称/), { target: { value: '实时计数' } });
    await act(async () => { (screen.getByText('录制 Agent 操作') as HTMLButtonElement).click(); });
    // 录制态出现，初始 0 步（recording_steps 契约：未捕获到动作时为 0）；
    // R4：本地起的 agent 录制按 recordingMode='agent' 显示「录制 Agent 操作中…」
    await waitFor(() => expect(screen.getByText(/正在录制「实时计数」 · 录制 Agent 操作中…已捕获 0 步/)).toBeTruthy());

    // 后端录制推进：recording_steps 0 → 3 → 7，轮询必须如实递增（用户看得见「在录到」）
    captured = 3;
    await waitFor(() => expect(screen.getByText(/已捕获 3 步/)).toBeTruthy());
    captured = 7;
    await waitFor(() => expect(screen.getByText(/已捕获 7 步/)).toBeTruthy());
    unmount();
  });

  it('0 步停止：saved:false → 警告原文上屏（warn 色），不刷新出宏（GET 不重拉、列表无新项）', async () => {
    const h = installFetchMock([
      routeJson('/api/cu-macros/record/start', { ok: true, name: '空宏' }),
      routeJson('/api/cu-macros/record/stop', {
        ok: true, saved: false, steps: 0, message: '未捕获到任何动作，宏未保存',
      }),
      routeJson('/api/cu-macros', { ok: true, macros: MACROS, recording: false, recording_steps: 0 }),
    ]);
    const { unmount } = render(<CuMacroPanel />);
    await waitFor(() => expect(screen.getByText('整理下载目录')).toBeTruthy());

    fireEvent.change(screen.getByPlaceholderText(/宏名称/), { target: { value: '空宏' } });
    await act(async () => { (screen.getByText('录制 Agent 操作') as HTMLButtonElement).click(); });
    await waitFor(() => expect(screen.getByText(/正在录制「空宏」/)).toBeTruthy());

    const getsBefore = getCount(h);
    await act(async () => { (screen.getByText('停止并保存') as HTMLButtonElement).click(); });
    expect(h.countOf('/api/cu-macros/record/stop')).toBe(1);

    // 警告原文上屏，且是 warn callout（语义色令牌联动，不钉色值）
    const warnText = await screen.findByText('未捕获到任何动作，宏未保存');
    const warnBox = warnText.closest('div') as HTMLElement;
    expect(styleColorIs(warnBox.style.background, colors.warnBg)).toBe(true);
    // 录制态退出
    await waitFor(() => expect(screen.queryByText(/正在录制/)).toBeNull());
    // ⛔ saved:false 不 refresh：GET 不得重拉（宏没落盘，列表无新项可刷）
    expect(getCount(h)).toBe(getsBefore);
    // 列表仍是原两条，无新宏「空宏」
    expect(screen.queryByText('空宏')).toBeNull();
    expect(screen.getByText('整理下载目录')).toBeTruthy();
    expect(screen.getByText('晨间例行')).toBeTruthy();
    unmount();
  });

  it('saved:true 停止仍走原流程：refresh 重拉列表', async () => {
    const h = installFetchMock([
      routeJson('/api/cu-macros/record/start', { ok: true, name: '晚间备份' }),
      routeJson('/api/cu-macros/record/stop', {
        ok: true, saved: true,
        macro: { id: 'cu-3', name: '晚间备份', created_at: '2026-09-18 11:00:00', steps: 2 },
      }),
      routeJson('/api/cu-macros', { ok: true, macros: MACROS, recording: false, recording_steps: 0 }),
    ]);
    const { unmount } = render(<CuMacroPanel />);
    await waitFor(() => expect(screen.getByText('整理下载目录')).toBeTruthy());
    fireEvent.change(screen.getByPlaceholderText(/宏名称/), { target: { value: '晚间备份' } });
    await act(async () => { (screen.getByText('录制 Agent 操作') as HTMLButtonElement).click(); });
    await waitFor(() => expect(screen.getByText(/正在录制「晚间备份」/)).toBeTruthy());
    const getsBefore = getCount(h);
    await act(async () => { (screen.getByText('停止并保存') as HTMLButtonElement).click(); });
    await waitFor(() => expect(screen.queryByText(/正在录制/)).toBeNull());
    await waitFor(() => expect(getCount(h)).toBeGreaterThan(getsBefore));
    unmount();
  });

  it('空宏按钮置灰：steps==0 → disabled + title「宏没有步骤」，点击不发回放请求', async () => {
    const h = installFetchMock([
      routeJson('/api/cu-macros', { ok: true, macros: [
        { id: 'cu-0', name: '历史遗留空宏', created_at: '2026-09-10 08:00:00', steps: 0 },
        MACROS[0],
      ], recording: false, recording_steps: 0 }),
    ]);
    const { unmount } = render(<CuMacroPanel />);
    await waitFor(() => expect(screen.getByText('历史遗留空宏')).toBeTruthy());
    expect(screen.getByText(/2026-09-10 08:00:00 · 0 步/)).toBeTruthy();

    const btns = screen.getAllByText('回放') as HTMLButtonElement[];
    expect(btns.length).toBe(2);
    // 行序 = 宏顺序：第一行是空宏 → 置灰 + title；第二行正常宏不受影响
    expect(btns[0].disabled).toBe(true);
    expect(btns[0].title).toBe('宏没有步骤');
    expect(btns[1].disabled).toBe(false);
    expect(btns[1].title).toBe('');

    fireEvent.click(btns[0]);
    await new Promise(r => setTimeout(r, 50));
    expect(h.countOf('/api/cu-macros/cu-0/replay')).toBe(0);
    unmount();
  });

  it('空宏 422 兜底：回放触发 422「宏没有可回放的步骤」→ detail 如实上屏', async () => {
    installFetchMock([
      routeJson('/api/cu-macros/cu-1/replay', { detail: '宏没有可回放的步骤' }, 422),
      routeJson('/api/cu-macros', { ok: true, macros: [MACROS[0]], recording: false, recording_steps: 0 }),
    ]);
    const { unmount } = render(<CuMacroPanel />);
    await waitFor(() => expect(screen.getByText('整理下载目录')).toBeTruthy());
    // MACROS[0] steps=3 按钮可用；后端若以 422 兜底（如并发下被清空），detail 必须上屏
    await act(async () => { (screen.getByText('回放') as HTMLButtonElement).click(); });
    await waitFor(() => expect(screen.getByText(/回放启动失败: 宏没有可回放的步骤/)).toBeTruthy());
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


describe('R4 宏面板用户手动录制', () => {
  /** 只数 GET /api/cu-macros（countOf 是 includes 匹配，会连 record/start 的 POST 一起数进去）。 */
  const getCount = (h: { calls: Array<{ method: string; url: string }> }) =>
    h.calls.filter(c => c.method === 'GET' && c.url.endsWith('/api/cu-macros')).length;

  it('模式入口渲染：「录制 Agent 操作」「录制我的操作」双按钮 + user 模式边界提示文案', async () => {
    installFetchMock([
      routeJson('/api/cu-macros', { ok: true, macros: [], recording: false, recording_mode: null }),
    ]);
    const { unmount } = render(<CuMacroPanel />);
    await waitFor(() => expect(screen.getByText(/暂无宏/)).toBeTruthy());

    const agentBtn = screen.getByText('录制 Agent 操作') as HTMLButtonElement;
    const userBtn = screen.getByText('录制我的操作') as HTMLButtonElement;
    expect(agentBtn.disabled).toBe(true);            // 名称为空两按钮都禁用
    expect(userBtn.disabled).toBe(true);
    fireEvent.change(screen.getByPlaceholderText(/宏名称/), { target: { value: '手动宏' } });
    expect(agentBtn.disabled).toBe(false);
    expect(userBtn.disabled).toBe(false);

    // 边界提示：录什么 / 不录什么（密码框）/ 产物去向
    expect(screen.getByText(/记录你的鼠标点击与键盘输入（密码框内容不会被记录）/)).toBeTruthy();
    expect(screen.getByText(/与 Agent 宏同格式，可回放、可交给 Agent 使用/)).toBeTruthy();
    unmount();
  });

  it('user 流程已授权：GET permission granted:true → POST start body 带 {name, mode:"user"}，进行态显示「录制我的操作中」', async () => {
    const h = installFetchMock([
      routeJson('/api/cu-macros/user-record/permission', { ok: true, granted: true }),
      routeJson('/api/cu-macros/record/start', { ok: true, name: '手动宏' }),
      routeJson('/api/cu-macros', { ok: true, macros: [], recording: false, recording_mode: null, recording_steps: 0 }),
    ]);
    const { unmount } = render(<CuMacroPanel />);
    await waitFor(() => expect(screen.getByText(/暂无宏/)).toBeTruthy());

    fireEvent.change(screen.getByPlaceholderText(/宏名称/), { target: { value: '手动宏' } });
    await act(async () => { (screen.getByText('录制我的操作') as HTMLButtonElement).click(); });

    // 前置 permission 已查；start body 必须带 mode:"user"（契约钉死字段）
    expect(h.countOf('/api/cu-macros/user-record/permission')).toBe(1);
    expect(h.lastBodyOf('/api/cu-macros/record/start')).toEqual({ name: '手动宏', mode: 'user' });
    await waitFor(() => expect(screen.getByText(/正在录制「手动宏」 · 录制我的操作中…已捕获 0 步/)).toBeTruthy());
    unmount();
  });

  it('agent 入口现状保留：POST start body 仍只带 name（不带 mode 字段）', async () => {
    const h = installFetchMock([
      routeJson('/api/cu-macros/record/start', { ok: true, name: '晚间备份' }),
      routeJson('/api/cu-macros', { ok: true, macros: [], recording: false, recording_mode: null, recording_steps: 0 }),
    ]);
    const { unmount } = render(<CuMacroPanel />);
    await waitFor(() => expect(screen.getByText(/暂无宏/)).toBeTruthy());
    fireEvent.change(screen.getByPlaceholderText(/宏名称/), { target: { value: '晚间备份' } });
    await act(async () => { (screen.getByText('录制 Agent 操作') as HTMLButtonElement).click(); });
    expect(h.lastBodyOf('/api/cu-macros/record/start')).toEqual({ name: '晚间备份' });
    // agent 入口不得触碰 permission 端点
    expect(h.countOf('/api/cu-macros/user-record/permission')).toBe(0);
    await waitFor(() => expect(screen.getByText(/录制 Agent 操作中…已捕获 0 步/)).toBeTruthy());
    unmount();
  });

  it('permission 未授权引导流：granted:false → 引导 callout 不发 start；「请求授权」→ POST request → 复查 granted:true → 自动补发 start', async () => {
    let granted = false;
    const permRoute: FetchRoute = (url, init) => {
      if (!url.includes('/api/cu-macros/user-record/permission')) return null;
      if (init?.method === 'POST') { granted = true; return jsonRes({ ok: true, granted: true }); } // 用户授权
      return jsonRes({ ok: true, granted });
    };
    const h = installFetchMock([
      permRoute,
      routeJson('/api/cu-macros/record/start', { ok: true, name: '手动宏' }),
      routeJson('/api/cu-macros', { ok: true, macros: [], recording: false, recording_mode: null, recording_steps: 0 }),
    ]);
    const { unmount } = render(<CuMacroPanel />);
    await waitFor(() => expect(screen.getByText(/暂无宏/)).toBeTruthy());

    fireEvent.change(screen.getByPlaceholderText(/宏名称/), { target: { value: '手动宏' } });
    await act(async () => { (screen.getByText('录制我的操作') as HTMLButtonElement).click(); });

    // 未授权 → 引导 callout（系统设置 → 隐私与安全性 → 输入监控），⛔ 不得发 start
    await waitFor(() => expect(screen.getByText(/系统设置 → 隐私与安全性 → 输入监控/)).toBeTruthy());
    expect(h.countOf('/api/cu-macros/record/start')).toBe(0);
    expect(h.countOf('/api/cu-macros/user-record/permission')).toBe(1);   // 首次 GET

    // 「请求授权」→ POST request → 再 GET 复查一次 granted → 已授权直接补发 user start
    await act(async () => { (screen.getByText('请求授权') as HTMLButtonElement).click(); });
    await waitFor(() => expect(screen.getByText(/正在录制「手动宏」 · 录制我的操作中/)).toBeTruthy());
    expect(h.countOf('/api/cu-macros/user-record/permission')).toBe(3);   // 首 GET + POST + 复查 GET
    expect(h.lastBodyOf('/api/cu-macros/record/start')).toEqual({ name: '手动宏', mode: 'user' });
    // 引导 callout 已撤
    expect(screen.queryByText(/系统设置 → 隐私与安全性 → 输入监控/)).toBeNull();
    unmount();
  });

  it('请求授权后复查仍未授权：引导 callout 保持，不发 start', async () => {
    const h = installFetchMock([
      routeJson('/api/cu-macros/user-record/permission', { ok: true, granted: false }),
      routeJson('/api/cu-macros/record/start', { ok: true, name: '手动宏' }),
      routeJson('/api/cu-macros', { ok: true, macros: [], recording: false, recording_mode: null, recording_steps: 0 }),
    ]);
    const { unmount } = render(<CuMacroPanel />);
    await waitFor(() => expect(screen.getByText(/暂无宏/)).toBeTruthy());
    fireEvent.change(screen.getByPlaceholderText(/宏名称/), { target: { value: '手动宏' } });
    await act(async () => { (screen.getByText('录制我的操作') as HTMLButtonElement).click(); });
    await waitFor(() => expect(screen.getByText(/系统设置 → 隐私与安全性 → 输入监控/)).toBeTruthy());

    await act(async () => { (screen.getByText('请求授权') as HTMLButtonElement).click(); });
    // 复查 granted:false → callout 仍在，start 始终未发
    await waitFor(() => expect(h.countOf('/api/cu-macros/user-record/permission')).toBe(3));
    expect(screen.getByText(/系统设置 → 隐私与安全性 → 输入监控/)).toBeTruthy();
    expect(h.countOf('/api/cu-macros/record/start')).toBe(0);
    unmount();
  });

  it('start 403 未授权（权限被收回）：detail 以 input_monitoring_not_granted 开头 → 落引导 callout，不上错误 callout', async () => {
    installFetchMock([
      routeJson('/api/cu-macros/user-record/permission', { ok: true, granted: true }),
      routeJson('/api/cu-macros/record/start',
        { detail: 'input_monitoring_not_granted: 请在系统设置中开启输入监控' }, 403),
      routeJson('/api/cu-macros', { ok: true, macros: [], recording: false, recording_mode: null, recording_steps: 0 }),
    ]);
    const { unmount } = render(<CuMacroPanel />);
    await waitFor(() => expect(screen.getByText(/暂无宏/)).toBeTruthy());
    fireEvent.change(screen.getByPlaceholderText(/宏名称/), { target: { value: '手动宏' } });
    await act(async () => { (screen.getByText('录制我的操作') as HTMLButtonElement).click(); });
    await waitFor(() => expect(screen.getByText(/系统设置 → 隐私与安全性 → 输入监控/)).toBeTruthy());
    // 403 走引导而非错误 callout
    expect(screen.queryByText(/开始录制失败/)).toBeNull();
    unmount();
  });

  it('互斥 409：回放中 user start → 409 detail 走错误 callout（不落引导 callout）', async () => {
    installFetchMock([
      routeJson('/api/cu-macros/user-record/permission', { ok: true, granted: true }),
      routeJson('/api/cu-macros/record/start', { detail: 'replay_busy: 回放进行中，无法开始录制' }, 409),
      routeJson('/api/cu-macros', { ok: true, macros: [], recording: false, recording_mode: null, recording_steps: 0 }),
    ]);
    const { unmount } = render(<CuMacroPanel />);
    await waitFor(() => expect(screen.getByText(/暂无宏/)).toBeTruthy());
    fireEvent.change(screen.getByPlaceholderText(/宏名称/), { target: { value: '手动宏' } });
    await act(async () => { (screen.getByText('录制我的操作') as HTMLButtonElement).click(); });
    await waitFor(() => expect(screen.getByText(/开始录制失败: replay_busy: 回放进行中/)).toBeTruthy());
    expect(screen.queryByText(/系统设置 → 隐私与安全性 → 输入监控/)).toBeNull();
    unmount();
  });

  it('互斥 409：agent start 已在录 → 409 detail 走错误 callout', async () => {
    installFetchMock([
      routeJson('/api/cu-macros/record/start', { detail: 'already_recording: 正在录制宏「X」' }, 409),
      routeJson('/api/cu-macros', { ok: true, macros: [], recording: false, recording_mode: null, recording_steps: 0 }),
    ]);
    const { unmount } = render(<CuMacroPanel />);
    await waitFor(() => expect(screen.getByText(/暂无宏/)).toBeTruthy());
    fireEvent.change(screen.getByPlaceholderText(/宏名称/), { target: { value: '重复' } });
    await act(async () => { (screen.getByText('录制 Agent 操作') as HTMLButtonElement).click(); });
    await waitFor(() => expect(screen.getByText(/开始录制失败: already_recording/)).toBeTruthy());
    unmount();
  });

  it('互斥 409：录制中 replay（前端态滞后）→ 409 detail 走错误 callout', async () => {
    installFetchMock([
      routeJson('/api/cu-macros/cu-1/replay', { detail: 'recording_busy: 正在录制宏，请先停止录制' }, 409),
      routeJson('/api/cu-macros', { ok: true, macros: [MACROS[0]], recording: false, recording_mode: null, recording_steps: 0 }),
    ]);
    const { unmount } = render(<CuMacroPanel />);
    await waitFor(() => expect(screen.getByText('整理下载目录')).toBeTruthy());
    await act(async () => { (screen.getByText('回放') as HTMLButtonElement).click(); });
    await waitFor(() => expect(screen.getByText(/回放启动失败: recording_busy: 正在录制宏/)).toBeTruthy());
    unmount();
  });

  it('录制中文案随 recording_mode=user：显示「录制我的操作中…已捕获 N 步」，停止按钮同一', async () => {
    installFetchMock([
      routeJson('/api/cu-macros', { ok: true, macros: [], recording: true, recording_mode: 'user', recording_steps: 5 }),
    ]);
    const { unmount } = render(<CuMacroPanel pollMs={20} />);
    // 挂载即录制中（另一窗口起的 user 录制）：模式与步骤数完全来自 GET /cu-macros
    await waitFor(() => expect(screen.getByText(/录制我的操作中…已捕获 5 步/)).toBeTruthy());
    expect(screen.getByText(/你的鼠标点击与键盘输入会记为一步/)).toBeTruthy();
    expect(screen.getByText('停止并保存')).toBeTruthy();
    unmount();
  });

  it('录制中文案随 recording_mode=agent（含缺键兜底）：显示「录制 Agent 操作中…已捕获 N 步」', async () => {
    installFetchMock([
      // 旧后端无 recording_mode 键 → 录制中按 agent 兜底
      routeJson('/api/cu-macros', { ok: true, macros: [], recording: true, recording_steps: 2 }),
    ]);
    const { unmount } = render(<CuMacroPanel pollMs={20} />);
    await waitFor(() => expect(screen.getByText(/录制 Agent 操作中…已捕获 2 步/)).toBeTruthy());
    expect(screen.getByText(/此后 Agent 的每个 CU 动作都会记为一步/)).toBeTruthy();
    unmount();
  });

  it('user 模式 0 步停止：saved:false 同样走警告 callout 分支（warn 色），不 refresh 出宏', async () => {
    const h = installFetchMock([
      routeJson('/api/cu-macros/user-record/permission', { ok: true, granted: true }),
      routeJson('/api/cu-macros/record/start', { ok: true, name: '空手动宏' }),
      routeJson('/api/cu-macros/record/stop', {
        ok: true, saved: false, steps: 0, message: '未捕获到任何动作，宏未保存',
      }),
      routeJson('/api/cu-macros', { ok: true, macros: MACROS, recording: false, recording_mode: null, recording_steps: 0 }),
    ]);
    const { unmount } = render(<CuMacroPanel />);
    await waitFor(() => expect(screen.getByText('整理下载目录')).toBeTruthy());

    fireEvent.change(screen.getByPlaceholderText(/宏名称/), { target: { value: '空手动宏' } });
    await act(async () => { (screen.getByText('录制我的操作') as HTMLButtonElement).click(); });
    await waitFor(() => expect(screen.getByText(/正在录制「空手动宏」 · 录制我的操作中/)).toBeTruthy());

    const getsBefore = getCount(h);
    await act(async () => { (screen.getByText('停止并保存') as HTMLButtonElement).click(); });
    expect(h.countOf('/api/cu-macros/record/stop')).toBe(1);

    // 警告原文上屏（warn callout），录制态退出，不 refresh（GET 不重拉、列表无新宏）
    const warnText = await screen.findByText('未捕获到任何动作，宏未保存');
    const warnBox = warnText.closest('div') as HTMLElement;
    expect(styleColorIs(warnBox.style.background, colors.warnBg)).toBe(true);
    await waitFor(() => expect(screen.queryByText(/正在录制/)).toBeNull());
    expect(getCount(h)).toBe(getsBefore);
    expect(screen.queryByText('空手动宏')).toBeNull();
    unmount();
  });
});
