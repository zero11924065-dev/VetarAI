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
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with VetarAI. If not, see <https://www.gnu.org/licenses/>.
 */
/**
 * 0.4.29 批 P1：模型包管理器面板测试。
 * 覆盖：目录渲染 / 空源引导 / 安装确认弹窗流（含境外来源勾选开代理的顺序）/
 *   进度事件驱动进度条 / 取消 / 卸载 / toggle / 源错误警告条 /
 *   已安装区警示标记 / download_error 卡片文案 / 目录源保存 / 设置开关写入 config。
 * 进度事件不走真 SSE——直接 emit(APP_RESOURCE_CHANGED, ...) 进事件总线
 * （面板订阅的是总线；appEvents 的 resource_changed 分支全量透传 data 已有
 *  appEvents.test.ts 兜底）。
 */
import { describe, it, expect, vi, beforeEach } from 'vitest';
import { render, screen, waitFor, act } from '@testing-library/react';
import React from 'react';
import { ModelPacksPanel } from '../panels/ModelPacksPanel';
import { SettingsPanel } from '../panels/SettingsPanel';
import { emit, __resetEventsForTest } from '../events';
import { APP_RESOURCE_CHANGED } from '../appEvents';
import { jsonRes, installFetchMock, routeJson, type FetchRoute } from './helpers/fetchMock';

// confirmDialog 命令式 API mock：各用例自行设定返回值并捕获 opts
const { confirmMock } = vi.hoisted(() => ({ confirmMock: vi.fn() }));
vi.mock('../Dialog', () => ({
  confirmDialog: (opts: unknown) => confirmMock(opts),
  alertDialog: vi.fn(async () => true),
  promptDialog: vi.fn(async () => null),
  choiceDialog: vi.fn(async () => null),
}));

const CAT_ENTRY = {
  pack_id: 'whisper-small',
  name: 'Whisper Small',
  task: 'asr',
  format: 'onnx',
  driver: 'onnx-asr',
  version: '1.2.0',
  description: '多语言语音转文字模型',
  size_bytes: 461 * 1024 * 1024,
  homepage: 'https://example.com/whisper',
  license: 'MIT',
  files: [{ path: 'model.onnx', size_bytes: 461 * 1024 * 1024, sha256: 'abcdef1234567890ff', sources: ['https://cdn.example.com/model.onnx'] }],
  source: 'https://models.example.com/catalog.json',
  installed: false,
  enabled: false,
  installed_version: '',
};

const INSTALLED_PACK = {
  pack_id: 'qwen-chat',
  name: 'Qwen 对话模型',
  description: '本地对话模型',
  version: '2.0.0',
  task: 'chat',
  format: 'gguf',
  driver: 'llama.cpp',
  status: 'installed',
  enabled: true,
  installed_at: '2026-01-01 10:00',
  files: [{ path: 'model.gguf', size_bytes: 100, sha256: 'aa' }],
  sha256_ok: true,
  size_bytes: 2 * 1024 ** 3,
  missing_files: [],
  has_partial: false,
  dir: '/data/models/packs/qwen-chat',
};

const CFG = {
  model_packs_dir: '',
  model_pack_catalog_urls: ['https://models.example.com/catalog.json'],
  confirm_model_pack_download: true,
  network_switch: 'auto',
};

interface RespOverrides {
  catalog?: unknown;
  installed?: unknown;
  config?: unknown;
}

/** 面板三端点 + 写操作路由。注意 catalog 路由必须在 '/model-packs' 之前（子串包含）。 */
function setupPanelFetch(over: RespOverrides = {}) {
  const catalogResp = over.catalog ?? { packs: [CAT_ENTRY], sources: 1, source_errors: [] };
  const installedResp = over.installed ?? { packs: [] };
  const configResp = over.config ?? { ...CFG };
  const writeRoutes: FetchRoute[] = [
    (url, init) => (init?.method === 'POST' && url.includes('/model-packs/install') ? jsonRes({ accepted: true, pack_id: 'whisper-small' }) : null),
    (url, init) => (init?.method === 'POST' && url.includes('/model-packs/cancel') ? jsonRes({ cancelled: true, pack_id: 'whisper-small' }) : null),
    (url, init) => (init?.method === 'POST' && url.includes('/toggle') ? jsonRes({ ok: true, enabled: false }) : null),
    (url, init) => (init?.method === 'DELETE' && url.includes('/model-packs/') ? jsonRes({ deleted: true }) : null),
    (url, init) => (init?.method === 'PUT' && url.includes('/config') ? jsonRes({ ...(configResp as object) }) : null),
  ];
  return installFetchMock([
    ...writeRoutes,
    routeJson('/model-packs/catalog', catalogResp),
    routeJson('/model-packs', installedResp),
    routeJson('/config', configResp),
  ]);
}

/** GET /model-packs（已安装列表，非 catalog）的命中次数。 */
function installedListCount(h: ReturnType<typeof setupPanelFetch>): number {
  return h.calls.filter(c => c.method === 'GET' && c.url.endsWith('/model-packs')).length;
}

beforeEach(() => {
  vi.restoreAllMocks();
  confirmMock.mockReset();
  confirmMock.mockResolvedValue(false);
  __resetEventsForTest();
});

describe('0.4.29 模型包面板 · 目录区', () => {
  it('目录渲染：名称/任务徽标/版本/大小/描述/来源 host/安装按钮', async () => {
    setupPanelFetch();
    const { unmount } = render(<ModelPacksPanel />);
    await waitFor(() => expect(screen.getByText('Whisper Small')).toBeTruthy(), { timeout: 3000 });
    expect(screen.getByText('语音转文字')).toBeTruthy();          // asr 徽标
    expect(screen.getByText('v1.2.0')).toBeTruthy();
    expect(screen.getByText('461.0 MB')).toBeTruthy();            // 大小格式化
    expect(screen.getByText('多语言语音转文字模型')).toBeTruthy();
    expect(screen.getByText(/来源：models\.example\.com/)).toBeTruthy();
    expect(screen.getByText('安装')).toBeTruthy();
    expect(screen.getByText('尚未安装任何模型包。从上方目录选择安装。')).toBeTruthy();
    unmount();
  });

  it('空目录且无源 → 引导文案（去下方加目录源，支持 file://）', async () => {
    setupPanelFetch({
      catalog: { packs: [], sources: 0, source_errors: [] },
      config: { ...CFG, model_pack_catalog_urls: [] },
    });
    const { unmount } = render(<ModelPacksPanel />);
    await waitFor(() => expect(screen.getByText(/还没有配置模型包目录源/)).toBeTruthy(), { timeout: 3000 });
    // 引导语指向下方目录源设置区并点明 file:// 支持（该句只在引导文案中出现，placeholder 里没有）
    expect(screen.getByText(/保存后这里会列出可安装的模型包/)).toBeTruthy();
    unmount();
  });

  it('目录源失败 → 警告条显示源与错误，不拖死其余条目', async () => {
    setupPanelFetch({
      catalog: {
        packs: [CAT_ENTRY],
        sources: 1,
        source_errors: [{ source: 'https://bad.example.com/c.json', error: '连接超时' }],
      },
    });
    const { unmount } = render(<ModelPacksPanel />);
    await waitFor(() => {
      expect(screen.getByText(/目录源 https:\/\/bad\.example\.com\/c\.json 拉取失败：连接超时/)).toBeTruthy();
    }, { timeout: 3000 });
    expect(screen.getByText('Whisper Small')).toBeTruthy();       // 好源的条目仍在
    unmount();
  });

  it('已装标记：catalog 条目 installed=true → 显示徽标且安装按钮禁用', async () => {
    setupPanelFetch({
      catalog: { packs: [{ ...CAT_ENTRY, installed: true, installed_version: '1.2.0' }], sources: 1, source_errors: [] },
    });
    const { unmount } = render(<ModelPacksPanel />);
    await waitFor(() => expect(screen.getByText('已安装', { selector: 'span' })).toBeTruthy(), { timeout: 3000 });
    const btn = screen.getByText('已安装', { selector: 'button' }) as HTMLButtonElement;
    expect(btn.disabled).toBe(true);
    unmount();
  });
});

describe('0.4.29 模型包面板 · 安装确认流', () => {
  it('确认弹窗：境外来源 + 标准联网 → 附全量联网勾选；确认且勾选 → 先 PUT proxy 再 install', async () => {
    const handle = setupPanelFetch();
    let captured: any = null;
    confirmMock.mockImplementation(async (opts: any) => {
      captured = opts;
      opts.onCheckbox?.(true);            // 用户保持默认勾选并确认
      return true;
    });
    const { unmount } = render(<ModelPacksPanel />);
    await waitFor(() => expect(screen.getByText('安装')).toBeTruthy(), { timeout: 3000 });
    await act(async () => { screen.getByText('安装').click(); });
    await waitFor(() => {
      expect(handle.calls.some(c => c.method === 'POST' && c.url.includes('/model-packs/install'))).toBe(true);
    }, { timeout: 3000 });

    // 弹窗形态：标题 + checkbox（境外 host 非 .cn 且 network_switch=auto）
    expect(confirmMock).toHaveBeenCalledTimes(1);
    expect(captured.title).toBe('下载模型包确认');
    expect(captured.checkboxLabel).toContain('同时开启全量联网');
    expect(captured.checkboxDefault).toBe(true);
    expect(captured.danger).toBeUndefined();           // 下载确认非危险操作

    // 顺序：PUT /config {network_switch:'proxy'} 必须先于 POST install
    const putIdx = handle.calls.findIndex(c => c.method === 'PUT' && c.url.includes('/config'));
    const postIdx = handle.calls.findIndex(c => c.method === 'POST' && c.url.includes('/model-packs/install'));
    expect(putIdx).toBeGreaterThanOrEqual(0);
    expect(postIdx).toBeGreaterThanOrEqual(0);
    expect(putIdx).toBeLessThan(postIdx);
    expect(handle.lastBodyOf('/config')).toEqual({ network_switch: 'proxy' });

    // install 载荷：pack_id + catalog_entry 原样回传
    const body = handle.lastBodyOf('/model-packs/install');
    expect(body.pack_id).toBe('whisper-small');
    expect(body.catalog_entry.pack_id).toBe('whisper-small');
    expect(body.catalog_entry.task).toBe('asr');
    unmount();
  });

  it('确认弹窗取消 → 不发 install、不切代理', async () => {
    const handle = setupPanelFetch();
    confirmMock.mockResolvedValue(false);
    const { unmount } = render(<ModelPacksPanel />);
    await waitFor(() => expect(screen.getByText('安装')).toBeTruthy(), { timeout: 3000 });
    await act(async () => { screen.getByText('安装').click(); });
    await waitFor(() => expect(confirmMock).toHaveBeenCalledTimes(1), { timeout: 3000 });
    expect(handle.calls.filter(c => c.url.includes('/model-packs/install')).length).toBe(0);
    expect(handle.calls.filter(c => c.method === 'PUT').length).toBe(0);
    unmount();
  });

  it('confirm_model_pack_download=false → 不弹窗直接安装', async () => {
    const handle = setupPanelFetch({ config: { ...CFG, confirm_model_pack_download: false } });
    const { unmount } = render(<ModelPacksPanel />);
    await waitFor(() => expect(screen.getByText('安装')).toBeTruthy(), { timeout: 3000 });
    await act(async () => { screen.getByText('安装').click(); });
    await waitFor(() => {
      expect(handle.calls.some(c => c.method === 'POST' && c.url.includes('/model-packs/install'))).toBe(true);
    }, { timeout: 3000 });
    expect(confirmMock).not.toHaveBeenCalled();
    unmount();
  });

  it('境内来源（.cn）→ 弹窗但不附全量联网勾选', async () => {
    setupPanelFetch({
      catalog: { packs: [{ ...CAT_ENTRY, source: 'https://models.example.cn/catalog.json' }], sources: 1, source_errors: [] },
      config: { ...CFG, model_pack_catalog_urls: ['https://models.example.cn/catalog.json'] },
    });
    let captured: any = null;
    confirmMock.mockImplementation(async (opts: any) => { captured = opts; return false; });
    const { unmount } = render(<ModelPacksPanel />);
    await waitFor(() => expect(screen.getByText('安装')).toBeTruthy(), { timeout: 3000 });
    await act(async () => { screen.getByText('安装').click(); });
    await waitFor(() => expect(confirmMock).toHaveBeenCalledTimes(1), { timeout: 3000 });
    expect(captured.checkboxLabel).toBeUndefined();
    unmount();
  });
});

describe('0.4.29 模型包面板 · 下载进度事件', () => {
  it('download_start/progress 驱动进度条（received/total → 50%）；download_done 重拉并轻提示', async () => {
    const handle = setupPanelFetch();
    const { unmount } = render(<ModelPacksPanel />);
    await waitFor(() => expect(screen.getByText('安装')).toBeTruthy(), { timeout: 3000 });
    const before = installedListCount(handle);

    await act(async () => {
      emit(APP_RESOURCE_CHANGED, {
        resource: 'model_pack', action: 'download_start', pack_id: 'whisper-small',
        total_bytes: 1000, file_count: 1, name: 'Whisper Small', version: '1.2.0',
      });
    });
    // 下载中：安装按钮换成取消按钮，进度条 0%
    await waitFor(() => expect(screen.getByText('取消')).toBeTruthy(), { timeout: 3000 });
    expect(screen.queryByText('安装')).toBeNull();

    await act(async () => {
      emit(APP_RESOURCE_CHANGED, {
        resource: 'model_pack', action: 'download_progress', pack_id: 'whisper-small',
        file: 'model.onnx', file_received: 500, file_total: 1000,
        received_bytes: 500, total_bytes: 1000,
      });
    });
    await waitFor(() => {
      const bar = document.querySelector('[data-progress-bar="whisper-small"]') as HTMLElement;
      expect(bar).toBeTruthy();
      expect(bar.style.width).toBe('50%');
    }, { timeout: 3000 });
    expect(screen.getByText(/50%/)).toBeTruthy();

    await act(async () => {
      emit(APP_RESOURCE_CHANGED, { resource: 'model_pack', action: 'download_done', pack_id: 'whisper-small', total_bytes: 1000 });
    });
    // done → 进度条消失、轻提示出现、两区重拉
    await waitFor(() => expect(screen.getByText(/模型包 whisper-small 安装完成/)).toBeTruthy(), { timeout: 3000 });
    expect(document.querySelector('[data-progress-bar="whisper-small"]')).toBeNull();
    expect(installedListCount(handle)).toBeGreaterThan(before);
    unmount();
  });

  it('下载中点取消 → POST /model-packs/cancel 带 pack_id', async () => {
    const handle = setupPanelFetch();
    const { unmount } = render(<ModelPacksPanel />);
    await waitFor(() => expect(screen.getByText('安装')).toBeTruthy(), { timeout: 3000 });
    await act(async () => {
      emit(APP_RESOURCE_CHANGED, {
        resource: 'model_pack', action: 'download_start', pack_id: 'whisper-small',
        total_bytes: 1000, file_count: 1, name: 'Whisper Small', version: '1.2.0',
      });
    });
    await waitFor(() => expect(screen.getByText('取消')).toBeTruthy(), { timeout: 3000 });
    await act(async () => { screen.getByText('取消').click(); });
    await waitFor(() => {
      expect(handle.calls.some(c => c.method === 'POST' && c.url.includes('/model-packs/cancel'))).toBe(true);
    }, { timeout: 3000 });
    expect(handle.lastBodyOf('/model-packs/cancel')).toEqual({ pack_id: 'whisper-small' });
    unmount();
  });

  it('download_error → 中文错误文案显示在卡片上，进度条消失', async () => {
    setupPanelFetch();
    const { unmount } = render(<ModelPacksPanel />);
    await waitFor(() => expect(screen.getByText('安装')).toBeTruthy(), { timeout: 3000 });
    await act(async () => {
      emit(APP_RESOURCE_CHANGED, {
        resource: 'model_pack', action: 'download_start', pack_id: 'whisper-small',
        total_bytes: 1000, file_count: 1, name: 'Whisper Small', version: '1.2.0',
      });
    });
    await waitFor(() => expect(screen.getByText('取消')).toBeTruthy(), { timeout: 3000 });
    await act(async () => {
      emit(APP_RESOURCE_CHANGED, {
        resource: 'model_pack', action: 'download_error', pack_id: 'whisper-small',
        error: '下载失败：全部来源不可用',
      });
    });
    await waitFor(() => expect(screen.getByText(/下载失败：全部来源不可用/)).toBeTruthy(), { timeout: 3000 });
    expect(document.querySelector('[data-progress-bar="whisper-small"]')).toBeNull();
    unmount();
  });
});

describe('0.4.29 模型包面板 · 已安装区', () => {
  it('行渲染 + 卸载流：confirmDialog(danger) 确认后发 DELETE', async () => {
    const handle = setupPanelFetch({ installed: { packs: [INSTALLED_PACK] } });
    confirmMock.mockResolvedValue(true);
    const { unmount } = render(<ModelPacksPanel />);
    await waitFor(() => expect(screen.getByText('Qwen 对话模型')).toBeTruthy(), { timeout: 3000 });
    expect(screen.getByText('对话')).toBeTruthy();                 // chat 徽标
    expect(screen.getByText('gguf')).toBeTruthy();
    expect(screen.getByText('2.0 GB')).toBeTruthy();

    await act(async () => { screen.getByText('卸载').click(); });
    await waitFor(() => {
      expect(handle.calls.some(c => c.method === 'DELETE' && c.url.includes('/model-packs/qwen-chat'))).toBe(true);
    }, { timeout: 3000 });
    const opts = confirmMock.mock.calls[0][0] as any;
    expect(opts.danger).toBe(true);
    expect(opts.title).toBe('卸载模型包');
    unmount();
  });

  it('卸载弹窗取消 → 不发 DELETE', async () => {
    const handle = setupPanelFetch({ installed: { packs: [INSTALLED_PACK] } });
    confirmMock.mockResolvedValue(false);
    const { unmount } = render(<ModelPacksPanel />);
    await waitFor(() => expect(screen.getByText('卸载')).toBeTruthy(), { timeout: 3000 });
    await act(async () => { screen.getByText('卸载').click(); });
    await waitFor(() => expect(confirmMock).toHaveBeenCalledTimes(1), { timeout: 3000 });
    expect(handle.calls.filter(c => c.method === 'DELETE').length).toBe(0);
    unmount();
  });

  it('启用开关：点「禁用」→ POST toggle {enabled:false}，按钮翻转为「启用」', async () => {
    const handle = setupPanelFetch({ installed: { packs: [INSTALLED_PACK] } });
    const { unmount } = render(<ModelPacksPanel />);
    await waitFor(() => expect(screen.getByText('禁用')).toBeTruthy(), { timeout: 3000 });
    await act(async () => { screen.getByText('禁用').click(); });
    await waitFor(() => {
      expect(handle.calls.some(c => c.method === 'POST' && c.url.includes('/model-packs/qwen-chat/toggle'))).toBe(true);
    }, { timeout: 3000 });
    expect(handle.lastBodyOf('/toggle')).toEqual({ enabled: false });
    await waitFor(() => expect(screen.getByText('启用')).toBeTruthy(), { timeout: 3000 });
    unmount();
  });

  it('缺文件 / sha256_ok=false / has_partial → 警示标记与续装提示', async () => {
    setupPanelFetch({
      installed: {
        packs: [{ ...INSTALLED_PACK, sha256_ok: false, missing_files: ['model.gguf'], has_partial: true }],
      },
    });
    const { unmount } = render(<ModelPacksPanel />);
    await waitFor(() => expect(screen.getByText('校验未通过')).toBeTruthy(), { timeout: 3000 });
    expect(screen.getByText(/缺失文件：model\.gguf/)).toBeTruthy();
    expect(screen.getByText(/有未完成下载，可继续安装/)).toBeTruthy();
    unmount();
  });
});

describe('0.4.29 模型包面板 · 目录源设置区', () => {
  it('保存目录源：多行文本框按行拆分 PUT config，并给出已保存反馈', async () => {
    const handle = setupPanelFetch();
    const { unmount } = render(<ModelPacksPanel />);
    await waitFor(() => expect(screen.getByText('保存目录源')).toBeTruthy(), { timeout: 3000 });

    const box = document.querySelector('textarea') as HTMLTextAreaElement;
    expect(box).toBeTruthy();
    await act(async () => {
      const setter = Object.getOwnPropertyDescriptor(window.HTMLTextAreaElement.prototype, 'value')!.set!;
      setter.call(box, 'https://a.example.com/packs.json\n\nfile:///Users/me/packs/');
      box.dispatchEvent(new Event('input', { bubbles: true }));
    });
    await act(async () => { screen.getByText('保存目录源').click(); });
    await waitFor(() => {
      const puts = handle.calls.filter(c => c.method === 'PUT' && c.url.includes('/config'));
      expect(puts.length).toBe(1);
    }, { timeout: 3000 });
    expect(handle.lastBodyOf('/config')).toEqual({
      model_pack_catalog_urls: ['https://a.example.com/packs.json', 'file:///Users/me/packs/'],
    });
    await waitFor(() => expect(screen.getByText('已保存 ✓')).toBeTruthy(), { timeout: 3000 });
    unmount();
  });

  it('保存安装目录：单行输入留空 = 默认；非空值原样 PUT', async () => {
    const handle = setupPanelFetch();
    const { unmount } = render(<ModelPacksPanel />);
    await waitFor(() => expect(screen.getByText('保存目录')).toBeTruthy(), { timeout: 3000 });
    const dirInput = screen.getByPlaceholderText(/留空使用默认安装根/) as HTMLInputElement;
    await act(async () => {
      const setter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value')!.set!;
      setter.call(dirInput, '~/mypacks');
      dirInput.dispatchEvent(new Event('input', { bubbles: true }));
    });
    await act(async () => { screen.getByText('保存目录').click(); });
    await waitFor(() => {
      expect(handle.lastBodyOf('/config')).toEqual({ model_packs_dir: '~/mypacks' });
    }, { timeout: 3000 });
    unmount();
  });
});

describe('0.4.29 模型包面板 · 资源变更订阅', () => {
  it('写操作事件（update/delete）→ 重拉两区；其他资源事件不触发', async () => {
    const handle = setupPanelFetch();
    const { unmount } = render(<ModelPacksPanel />);
    await waitFor(() => expect(screen.getByText('安装')).toBeTruthy(), { timeout: 3000 });
    const before = installedListCount(handle);

    await act(async () => {
      emit(APP_RESOURCE_CHANGED, { resource: 'plugin', action: 'update' });   // 无关资源
    });
    expect(installedListCount(handle)).toBe(before);

    await act(async () => {
      emit(APP_RESOURCE_CHANGED, { resource: 'model_pack', action: 'delete', pack_id: 'qwen-chat' });
    });
    await waitFor(() => expect(installedListCount(handle)).toBeGreaterThan(before), { timeout: 3000 });
    unmount();
  });
});

describe('0.4.29 基础设置 · 模型包下载确认开关', () => {
  it('「下载模型包前必须询问我」开关写入 confirm_model_pack_download', async () => {
    const handle = installFetchMock([
      (url, init) => (init?.method === 'PUT' && url.includes('/config') ? jsonRes({}) : null),
      routeJson('/config', { confirm_model_pack_download: true, network_switch: 'auto', plugin_repos: [], egress_proxy_required: [] }),
      routeJson('/inference/models', []),
    ]);
    const { unmount } = render(<SettingsPanel embedded onOpenLogs={() => {}} onOpenDataDir={() => {}} />);
    await waitFor(() => expect(screen.getByText('下载模型包前必须询问我')).toBeTruthy(), { timeout: 3000 });

    const label = screen.getByText('下载模型包前必须询问我').closest('label')!;
    const checkbox = label.querySelector('input[type="checkbox"]') as HTMLInputElement;
    expect(checkbox.checked).toBe(true);                       // 默认开
    await act(async () => { checkbox.click(); });
    await waitFor(() => {
      expect(handle.lastBodyOf('/config')).toEqual({ confirm_model_pack_download: false });
    }, { timeout: 3000 });
    unmount();
  });
});
