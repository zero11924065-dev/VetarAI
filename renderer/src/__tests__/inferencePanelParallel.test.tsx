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
import { render, screen, waitFor, act, within } from '@testing-library/react';
import React from 'react';
import { InferencePanel } from '../panels/InferencePanel';

import { jsonRes } from './helpers/fetchMock';

/**
 * 0.4.30（W2）推理面板并行化：模型包与后端模型并存于统一列表。
 *
 * 后端契约（0.4.30 批）：inference_backend 保持 ollama/openai_compatible 时，
 * 对话按 model 名自动路由——model=模型包 pack_id 走模型包引擎，其它走活动后端；
 * /inference/models 统一返回两类条目，模型包带 source:'model_pack'。
 *
 * 被测契约：
 *   - 「模型包」排他第三卡移除（后端选择只剩 Ollama / OpenAI 兼容两张卡）；
 *   - 模型包条目带「模型包」来源徽标，普通模型无徽标；
 *   - 选中模型包只存 default_model=pack_id、**不动 inference_backend**，
 *     并提示「换装编排」（会暂停其它本地模型）；选普通模型存 default_model=名字、无换装提示；
 *   - 旧配置 inference_backend=model_package 的用户面板兼容显示（不炸、可切回）；
 *   - 空态文案覆盖「后端离线/无模型/无已启用模型包」。
 *
 * 覆盖：
 *   L1 统一列表徽标（包有/普通无；包的删除钮不出现——卸载归「模型包」面板）
 *   L2 选模型包为默认：PUT 只写 default_model、inference_backend 原值不变、换装提示可见
 *   L3 选普通模型为默认：PUT 写 default_model=名字、无换装提示
 *   L4 旧配置 model_package：兼容提示 + 仅两张后端卡 + 状态区仍可辨识
 *   L5 空态文案；L6 已是默认的行显示「当前默认」且无「设为默认」钮
 */
if (typeof (globalThis as any).localStorage === 'undefined') {
  (globalThis as any).localStorage = {
    _d: {} as Record<string, string>,
    getItem(k: string) { return this._d[k] ?? null; },
    setItem(k: string, v: string) { this._d[k] = String(v); },
    removeItem(k: string) { delete this._d[k]; },
    clear() { this._d = {}; },
  };
}

beforeEach(() => { vi.restoreAllMocks(); localStorage.clear(); });

const OLLAMA_STATUS = { backend: 'ollama', base_url: 'http://localhost:11434', online: true, detail: '',
  capabilities: { tools: true, vision: true, pull: true, delete: true } };

/** 安装 fetch 桩；捕获 PUT /config 的载荷。 */
function install(opts: { cfg: any; models: any[]; status?: any }) {
  const putBodies: any[] = [];
  const impl: typeof fetch = async (url, init) => {
    const u = String(url);
    if (u.includes('/config') && String(init?.method || 'GET') === 'PUT') {
      try { putBodies.push(JSON.parse(String(init?.body ?? '{}'))); } catch { /* 忽略 */ }
      return jsonRes({ ok: true });
    }
    if (u.includes('/inference/status')) return jsonRes(opts.status ?? OLLAMA_STATUS);
    if (u.includes('/inference/models')) return jsonRes(opts.models);
    if (u.includes('/config')) return jsonRes(opts.cfg);
    return jsonRes([]);
  };
  vi.spyOn(globalThis, 'fetch').mockImplementation(impl);
  return { putBodies };
}

/** 按模型名取行元素（名字 span 的直接父 div 即行）。 */
function rowOf(name: string): HTMLElement {
  const el = screen.getByText(name);
  const row = el.closest('div');
  if (!row) throw new Error(`未找到模型行：${name}`);
  return row as HTMLElement;
}

describe('0.4.30 W2 推理面板并行化', () => {
  it('L1 统一列表：模型包带来源徽标，普通模型无徽标；包的删除入口不出现', async () => {
    install({
      cfg: { inference_backend: 'ollama' },
      models: [{ name: 'qwen3.8', size: 16_000_000_000 }, { name: 'chatlaw-gguf', size: 8_000_000_000, source: 'model_pack', context_length: 4096 }],
    });
    const { unmount } = render(<InferencePanel />);
    await waitFor(() => {
      expect(screen.getByText('qwen3.8')).toBeTruthy();
      expect(screen.getByText('chatlaw-gguf')).toBeTruthy();
    }, { timeout: 3000 });

    // 徽标唯一（仅包行）；普通行无徽标
    expect(within(rowOf('chatlaw-gguf')).getByText('模型包')).toBeTruthy();
    expect(within(rowOf('qwen3.8')).queryByText('模型包')).toBeFalsy();
    // 删除仅对活动后端模型开放（包的卸载归「模型包」面板）
    expect(within(rowOf('qwen3.8')).getByText('删除')).toBeTruthy();
    expect(within(rowOf('chatlaw-gguf')).queryByText('删除')).toBeFalsy();
    unmount();
  });

  it('L2 选模型包为默认：只存 default_model=pack_id、inference_backend 不变、出现换装编排提示', async () => {
    const { putBodies } = install({
      cfg: { inference_backend: 'ollama' },
      models: [{ name: 'qwen3.8' }, { name: 'chatlaw-gguf', source: 'model_pack' }],
    });
    const { unmount } = render(<InferencePanel />);
    await waitFor(() => expect(screen.getByText('chatlaw-gguf')).toBeTruthy(), { timeout: 3000 });

    await act(async () => { within(rowOf('chatlaw-gguf')).getByText('设为默认').click(); });

    await waitFor(() => expect(putBodies.length).toBe(1), { timeout: 3000 });
    // 核心契约：model=pack_id 落 default_model；inference_backend 保持原值（不动后端）
    expect(putBodies[0].default_model).toBe('chatlaw-gguf');
    expect(putBodies[0].inference_backend).toBe('ollama');
    // 换装编排提示（一句话，仿现有提示样式）
    await waitFor(() => expect(document.body.textContent).toContain('换装编排'), { timeout: 3000 });
    expect(document.body.textContent).toContain('暂停其它本地模型');
    unmount();
  });

  it('L3 选普通模型为默认：存 default_model=名字，无换装编排提示', async () => {
    const { putBodies } = install({
      cfg: { inference_backend: 'ollama' },
      models: [{ name: 'qwen3.8' }, { name: 'chatlaw-gguf', source: 'model_pack' }],
    });
    const { unmount } = render(<InferencePanel />);
    await waitFor(() => expect(screen.getByText('qwen3.8')).toBeTruthy(), { timeout: 3000 });

    await act(async () => { within(rowOf('qwen3.8')).getByText('设为默认').click(); });

    await waitFor(() => expect(putBodies.length).toBe(1), { timeout: 3000 });
    expect(putBodies[0].default_model).toBe('qwen3.8');
    expect(putBodies[0].inference_backend).toBe('ollama');
    await waitFor(() => expect(document.body.textContent).toContain('已选为默认模型：qwen3.8'), { timeout: 3000 });
    expect(document.body.textContent).not.toContain('换装编排');
    unmount();
  });

  it('L4 旧配置 inference_backend=model_package：兼容显示不炸，仅两张后端卡，可辨识状态', async () => {
    install({
      cfg: { inference_backend: 'model_package', inference_base_url: '' },
      status: { backend: 'model_package', base_url: 'http://127.0.0.1:52111/v1', online: true, detail: '',
        capabilities: { tools: true, vision: false, pull: false, delete: false } },
      models: [{ name: 'chatlaw-gguf', source: 'model_pack', context_length: 4096 }],
    });
    const { unmount } = render(<InferencePanel />);
    await waitFor(() => {
      expect(screen.getByText(/模型包 · 在线/)).toBeTruthy();
      expect(screen.getByText('chatlaw-gguf')).toBeTruthy();
    }, { timeout: 3000 });
    // 排他第三卡已移除：后端选择只剩两个单选
    expect(document.querySelectorAll('input[type="radio"]').length).toBe(2);
    // 旧配置兼容提示可见（引导切回常规配置）
    expect(document.body.textContent).toContain('旧版「模型包后端」配置');
    expect(document.body.textContent).toContain('并行可用');
    // 不渲染 OpenAI 兼容的地址表单
    expect(screen.queryByPlaceholderText(/http:\/\/localhost:1234\/v1/)).toBeFalsy();
    unmount();
  });

  it('L5 空态：无模型时文案覆盖后端离线与模型包指引', async () => {
    install({ cfg: { inference_backend: 'ollama' }, models: [] });
    const { unmount } = render(<InferencePanel />);
    await waitFor(() => {
      expect(screen.getByText(/暂无可用模型/)).toBeTruthy();
      expect(screen.getByText(/模型包安装并启用后也会出现在此列表/)).toBeTruthy();
    }, { timeout: 3000 });
    unmount();
  });

  it('L6 已是默认的模型行显示「当前默认」，不再出现「设为默认」', async () => {
    install({
      cfg: { inference_backend: 'ollama', default_model: 'chatlaw-gguf' },
      models: [{ name: 'qwen3.8' }, { name: 'chatlaw-gguf', source: 'model_pack' }],
    });
    const { unmount } = render(<InferencePanel />);
    await waitFor(() => expect(screen.getByText('chatlaw-gguf')).toBeTruthy(), { timeout: 3000 });

    expect(within(rowOf('chatlaw-gguf')).getByText('当前默认')).toBeTruthy();
    expect(within(rowOf('chatlaw-gguf')).queryByText('设为默认')).toBeFalsy();
    expect(within(rowOf('qwen3.8')).getByText('设为默认')).toBeTruthy();
    unmount();
  });
});
