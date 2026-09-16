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
 *
 * REQ-INFER-009（0.4.28）口径改写：组件从「onChange 直接校验保存」改为
 * 「草稿模式」——onChange 只写本地草稿，blur / Enter 才走 coerce 校验并提交；
 * 非法值提示错误且草稿保留不回弹。前三个旧用例只改**触发方式与时机假设**
 * （change 后补 blur、增加"未提交前不保存"断言），对 patch 内容的断言强度不变；
 * D1~D4 为新增用例，配套变异档见 scripts/mutate_frontend.py 第 20~25 档。
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
    // ⛔ 必须声明参数类型：否则 vi.fn 的 mock.calls 元素被推断为空元组 []，
    // 取 calls[i][0] 会报 TS2493（本文件曾因此漏过 typecheck）。
    const onSave = vi.fn(async (_patch: Record<string, any>) => {});
    render(<ModelOptionsEditor cfg={{ model_options: { 'qwen3.8': { num_ctx: 4096 } } }}
      busy={false} onSave={onSave} isOllama focus="qwen3.8" />);
    const input = screen.getByPlaceholderText('如 8192');
    expect((input as HTMLInputElement).value).toBe('4096');   // 已配置值回显
    // REQ-INFER-009（0.4.28）草稿模式：onChange 只写草稿，blur/Enter 才提交
    fireEvent.change(input, { target: { value: '8192' } });
    expect(onSave).not.toHaveBeenCalled();                    // 未提交前不保存
    fireEvent.blur(input);
    await waitFor(() => expect(onSave).toHaveBeenCalled());
    const patch = onSave.mock.calls[onSave.mock.calls.length - 1][0];
    expect(patch.model_options['qwen3.8'].num_ctx).toBe(8192);
  });

  it('清空某项 → 从 model_options 移除该键（回落模型默认）', async () => {
    // ⛔ 必须声明参数类型：否则 vi.fn 的 mock.calls 元素被推断为空元组 []，
    // 取 calls[i][0] 会报 TS2493（本文件曾因此漏过 typecheck）。
    const onSave = vi.fn(async (_patch: Record<string, any>) => {});
    render(<ModelOptionsEditor cfg={{ model_options: { 'qwen3.8': { temperature: 0.5 } } }}
      busy={false} onSave={onSave} isOllama focus="qwen3.8" />);
    const input = screen.getByPlaceholderText('0.0 ~ 2.0');
    expect((input as HTMLInputElement).value).toBe('0.5');
    // REQ-INFER-009（0.4.28）草稿模式：清空后 blur 提交 = 清空该参数
    fireEvent.change(input, { target: { value: '' } });
    expect(onSave).not.toHaveBeenCalled();                    // 未提交前不保存
    fireEvent.blur(input);
    await waitFor(() => expect(onSave).toHaveBeenCalled());
    const patch = onSave.mock.calls[onSave.mock.calls.length - 1][0];
    expect(patch.model_options['qwen3.8']).not.toHaveProperty('temperature');
  });

  it('越界值 → 显示错误且不调用 onSave（不注入坏值）', async () => {
    // ⛔ 必须声明参数类型：否则 vi.fn 的 mock.calls 元素被推断为空元组 []，
    // 取 calls[i][0] 会报 TS2493（本文件曾因此漏过 typecheck）。
    const onSave = vi.fn(async (_patch: Record<string, any>) => {});
    render(<ModelOptionsEditor cfg={{ model_options: { 'qwen3.8': {} } }}
      busy={false} onSave={onSave} isOllama focus="qwen3.8" />);
    // REQ-INFER-009（0.4.28）草稿模式：错误只在提交（blur/Enter）时出现
    const input = screen.getByPlaceholderText('0.0 ~ 2.0') as HTMLInputElement;
    fireEvent.change(input, { target: { value: '99' } });
    expect(onSave).not.toHaveBeenCalled();                    // onChange 不校验不保存
    fireEvent.blur(input);
    await waitFor(() => expect(screen.getByText(/不得大于 2/)).toBeTruthy());
    expect(onSave).not.toHaveBeenCalled();
    expect(input.value).toBe('99');                           // 草稿保留不回弹
  });

  // ── REQ-INFER-009（0.4.28）草稿模式新增用例 ─────────────────────────────
  // 变异测试：scripts/mutate_frontend.py 第 20~25 档对应守护 D1~D4 与上述改写用例。

  it('D1 逐键输入中间态不回弹：未提交前不校验、不保存，值逐步累积', async () => {
    // ⛔ 必须声明参数类型：否则 vi.fn 的 mock.calls 元素被推断为空元组 []，
    // 取 calls[i][0] 会报 TS2493（本文件曾因此漏过 typecheck）。
    const onSave = vi.fn(async (_patch: Record<string, any>) => {});
    render(<ModelOptionsEditor cfg={{ model_options: { 'qwen3.8': {} } }}
      busy={false} onSave={onSave} isOllama focus="qwen3.8" />);
    const input = screen.getByPlaceholderText('如 8192') as HTMLInputElement;
    // REQ-INFER-009 原始缺陷：num_ctx 下限 256，旧实现 onChange 逐键校验 →
    // 第一个数字（"2"）必越界 → 不保存 → 受控值回弹，根本输不进去。
    fireEvent.change(input, { target: { value: '2' } });
    expect(input.value).toBe('2');                 // 越界中间态也原样留在框内
    fireEvent.change(input, { target: { value: '25' } });
    expect(input.value).toBe('25');                // 逐步累积，不回弹
    fireEvent.change(input, { target: { value: '256' } });
    expect(input.value).toBe('256');
    expect(onSave).not.toHaveBeenCalled();         // 未 blur / Enter 前不保存
    expect(screen.queryByText(/不得小于 256/)).toBeNull();  // 未提交前不校验
    fireEvent.blur(input);                          // 补齐提交：合法值正常落库
    await waitFor(() => expect(onSave).toHaveBeenCalled());
    const patch = onSave.mock.calls[onSave.mock.calls.length - 1][0];
    expect(patch.model_options['qwen3.8'].num_ctx).toBe(256);
  });

  it('D2 blur 提交越界值 → 显示错误、草稿保留不回弹、不调用 onSave', async () => {
    // ⛔ 必须声明参数类型：否则 vi.fn 的 mock.calls 元素被推断为空元组 []，
    // 取 calls[i][0] 会报 TS2493（本文件曾因此漏过 typecheck）。
    const onSave = vi.fn(async (_patch: Record<string, any>) => {});
    render(<ModelOptionsEditor cfg={{ model_options: { 'qwen3.8': {} } }}
      busy={false} onSave={onSave} isOllama focus="qwen3.8" />);
    const input = screen.getByPlaceholderText('如 8192') as HTMLInputElement;
    fireEvent.change(input, { target: { value: '100' } });   // < 256 下限
    fireEvent.blur(input);
    await waitFor(() => expect(screen.getByText(/不得小于 256/)).toBeTruthy());
    expect(input.value).toBe('100');               // ⛔ 草稿保留：用户能接着改，不是被吞
    expect(onSave).not.toHaveBeenCalled();         // 不注入坏值
  });

  it('D3 Enter 提交合法值 → 调用 onSave 落库，草稿归一化同步为已存值', async () => {
    // ⛔ 必须声明参数类型：否则 vi.fn 的 mock.calls 元素被推断为空元组 []，
    // 取 calls[i][0] 会报 TS2493（本文件曾因此漏过 typecheck）。
    const onSave = vi.fn(async (_patch: Record<string, any>) => {});
    render(<ModelOptionsEditor cfg={{ model_options: { 'qwen3.8': {} } }}
      busy={false} onSave={onSave} isOllama focus="qwen3.8" />);
    const input = screen.getByPlaceholderText('如 8192') as HTMLInputElement;
    fireEvent.change(input, { target: { value: ' 8192 ' } });   // 带空白：提交时归一化
    expect(onSave).not.toHaveBeenCalled();         // 未提交前不保存
    fireEvent.keyDown(input, { key: 'Enter' });
    await waitFor(() => expect(onSave).toHaveBeenCalled());
    const patch = onSave.mock.calls[onSave.mock.calls.length - 1][0];
    expect(patch.model_options['qwen3.8'].num_ctx).toBe(8192);
    await waitFor(() => expect(input.value).toBe('8192'));   // 保存成功 → 草稿同步已存值
  });

  it('D4 外部配置刷新 → 未聚焦字段的草稿同步为已存值', async () => {
    // ⛔ 必须声明参数类型：否则 vi.fn 的 mock.calls 元素被推断为空元组 []，
    // 取 calls[i][0] 会报 TS2493（本文件曾因此漏过 typecheck）。
    const onSave = vi.fn(async (_patch: Record<string, any>) => {});
    const { rerender } = render(<ModelOptionsEditor
      cfg={{ model_options: { 'qwen3.8': { num_ctx: 4096 } } }}
      busy={false} onSave={onSave} isOllama focus="qwen3.8" />);
    const input = screen.getByPlaceholderText('如 8192') as HTMLInputElement;
    fireEvent.change(input, { target: { value: '999' } });     // 未提交的草稿
    expect(input.value).toBe('999');
    // Agent 改配置 / 其他入口保存后父级重拉（A13）→ 草稿以新已存值为准
    rerender(<ModelOptionsEditor
      cfg={{ model_options: { 'qwen3.8': { num_ctx: 8192 } } }}
      busy={false} onSave={onSave} isOllama focus="qwen3.8" />);
    await waitFor(() => expect(input.value).toBe('8192'));
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
