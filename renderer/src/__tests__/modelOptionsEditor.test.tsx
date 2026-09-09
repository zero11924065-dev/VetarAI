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
import { render, screen, waitFor, fireEvent } from '@testing-library/react';
import React from 'react';
import { ModelOptionsEditor } from '../panels/ModelOptionsEditor';
import { InferencePanel } from '../panels/InferencePanel';
import { jsonRes } from './helpers/fetchMock';

/**
 * 第 2 批（0.4.15）A2/A4：每模型推理参数编辑器测试。
 *
 * ⛔ 集成用例「模型名唯一」锁的是一个**本轮真实踩过并返工的坑**：
 * 最初把"新增配置"做成 ModelOptionsEditor 内部的模型下拉，结果模型列表与下拉
 * 各渲染一遍模型名 → `getByText('qwen3.8')` 报 "Found multiple elements"，
 * 打挂了 inferencePanel 既有测试。根因是 UI 冗余（不该改测试迁就），
 * 已改为"模型列表每行一个「参数」按钮就地配置"。
 * 这里用 `getAllByText(name).length === 1` 而非 getByText：
 * 渲染 0 次（空转）或 2 次（重复）都会失败，自带非空转校验。
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

function mockInferenceFetch(modelOptions: Record<string, any> = {}) {
  const impl: typeof fetch = async (url) => {
    const u = String(url);
    if (u.includes('/inference/status')) {
      return jsonRes({ backend: 'ollama', base_url: 'http://localhost:11434', online: true,
        detail: '', capabilities: { tools: true, vision: true, pull: true, delete: true } });
    }
    if (u.includes('/inference/models')) {
      return jsonRes([{ name: 'qwen3.8', size: 16_000_000_000, context_length: 262144 }]);
    }
    if (u.includes('/config')) {
      return jsonRes({ inference_backend: 'ollama', model_options: modelOptions });
    }
    return jsonRes([]);
  };
  vi.spyOn(globalThis, 'fetch').mockImplementation(impl);
}

beforeEach(() => { vi.restoreAllMocks(); localStorage.clear(); });

describe('ModelOptionsEditor 单元', () => {
  it('编辑 num_ctx → onSave 带正确的 model_options 结构', async () => {
    const onSave = vi.fn(async () => {});
    render(<ModelOptionsEditor cfg={{ model_options: { 'qwen3.8': { num_ctx: 4096 } } }}
      busy={false} onSave={onSave} isOllama focus="qwen3.8" />);
    const input = screen.getByPlaceholderText('如 8192');
    expect((input as HTMLInputElement).value).toBe('4096');   // 已配置值回显
    fireEvent.change(input, { target: { value: '8192' } });
    await waitFor(() => expect(onSave).toHaveBeenCalled());
    const patch = onSave.mock.calls[onSave.mock.calls.length - 1][0];
    expect(patch.model_options['qwen3.8'].num_ctx).toBe(8192);
  });

  it('清空某项 → 从 model_options 移除该键（回落模型默认）', async () => {
    const onSave = vi.fn(async () => {});
    render(<ModelOptionsEditor cfg={{ model_options: { 'qwen3.8': { temperature: 0.5 } } }}
      busy={false} onSave={onSave} isOllama focus="qwen3.8" />);
    const input = screen.getByPlaceholderText('0.0 ~ 2.0');
    expect((input as HTMLInputElement).value).toBe('0.5');
    fireEvent.change(input, { target: { value: '' } });
    await waitFor(() => expect(onSave).toHaveBeenCalled());
    const patch = onSave.mock.calls[onSave.mock.calls.length - 1][0];
    expect(patch.model_options['qwen3.8']).not.toHaveProperty('temperature');
  });

  it('越界值 → 显示错误且不调用 onSave（不注入坏值）', async () => {
    const onSave = vi.fn(async () => {});
    render(<ModelOptionsEditor cfg={{ model_options: { 'qwen3.8': {} } }}
      busy={false} onSave={onSave} isOllama focus="qwen3.8" />);
    fireEvent.change(screen.getByPlaceholderText('0.0 ~ 2.0'), { target: { value: '99' } });
    await waitFor(() => expect(screen.getByText(/不得大于 2/)).toBeTruthy());
    expect(onSave).not.toHaveBeenCalled();
  });

  it('openai 兼容后端 → num_ctx / top_k 置灰（该后端不支持）', () => {
    render(<ModelOptionsEditor cfg={{ model_options: { 'my-model': {} } }}
      busy={false} onSave={async () => {}} isOllama={false} focus="my-model" />);
    expect((screen.getByPlaceholderText('如 8192') as HTMLInputElement).disabled).toBe(true);
    // temperature 两个后端都支持 → 不置灰
    expect((screen.getByPlaceholderText('0.0 ~ 2.0') as HTMLInputElement).disabled).toBe(false);
    expect(screen.getByText(/num_ctx 与 top_k 不支持/)).toBeTruthy();
  });

  it('未配置任何模型 → 显示引导文案，不崩溃', () => {
    render(<ModelOptionsEditor cfg={{ model_options: {} }} busy={false}
      onSave={async () => {}} isOllama />);
    expect(screen.getByText(/尚未为任何模型配置参数/)).toBeTruthy();
  });
});

describe('InferencePanel 集成：模型名唯一性（锁本轮踩过的坑）', () => {
  it('未配置参数时，模型名只渲染一次（下拉已移除，无重复）', async () => {
    mockInferenceFetch({});
    render(<InferencePanel />);
    // ⛔ 用 length===1 而非 getByText：0 次=空转、2 次=重复渲染（旧下拉 bug），都要失败
    await waitFor(() => expect(screen.getAllByText('qwen3.8').length).toBe(1), { timeout: 3000 });
  });

  it('模型列表行提供「参数」按钮（就地配置入口）', async () => {
    mockInferenceFetch({});
    render(<InferencePanel />);
    await waitFor(() => expect(screen.getAllByText('qwen3.8').length).toBe(1), { timeout: 3000 });
    expect(screen.getByText('参数')).toBeTruthy();
  });
});
