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
import { describe, it, expect, vi, beforeEach } from 'vitest';
import { render, waitFor, fireEvent, act } from '@testing-library/react';
import React from 'react';
import { ChatPanel } from '../panels/ChatPanel';

import { jsonRes, sseRes, tokenEvent, doneEvent } from './helpers/fetchMock';

/**
 * 表#6（0.4.19）· 附件走【路径】而非【全文注入】（推模式 → 拉模式）。
 *
 * ⛔ 缺陷机制：解析全文（后端上限单文件 20 万字符）被拼进 user 消息正文 → 该正文**落库**，
 *   并在此后**每一轮**都随 apiMessages 发给模型。传一个 50 页 PDF，之后每次对话都重复携带它
 *   → 上下文被吃满、prefill 变慢（与 0.4.8「主 Agent 自读 90KB PDF 跑 20 分钟」同类机制）。
 *
 * ✅ 修法：正文只写**绝对路径 + 读取指令**，由 agent 自己 read_file
 *   （表#4 已让 read_file 真能解析 docx/xlsx/pptx/pdf，否则给路径等于没给）。
 *
 * ⛔ 退化路径必须守：拿不到 savedPath（会话未创建/落盘失败）时**仍全额注入**——
 *   否则用户彻底失去让 agent 看到该文件的能力，比上下文膨胀严重得多。
 *
 * 覆盖：
 *   T1 有 savedPath → 发给模型的正文含路径、含 read_file 指令、**不含解析全文**
 *   T2 无 savedPath → 退回全额注入（正文含解析全文 + 落盘失败提示）
 *   T3 用户原话不被附件段污染（正文仍以原话开头）
 *   T4 解析失败但有路径 → 仍给路径（agent 可自行决定读不读）
 *   T5 源码层：旧的"全文注入"写法已不存在（防回潮）
 *
 * ⛔ 断言对象是**真实发给后端的载荷**（sent[]），不是界面文本——界面显示什么与
 *   模型收到什么是两件事，本需求治的是后者。
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

// ⛔ 解析全文的探针字符串：只要它出现在发给模型的正文里，就说明仍在"推模式"。
//    刻意用足够长且唯一的串，避免与界面文案偶然重合。
const PARSED_TEXT = '借条正文探针XYZ：今借到王永斌人民币贰拾叁万玖仟玖佰元整，借款人张元，日期二〇二三年二月一日。';
const SAVED_PATH = '/Users/vetar/.subagent/projects/p1/attachments/s1/借条.pdf';

/** 安装 fetch 桩：/attachments/parse 返回可控的 text / saved_path；捕获 stream 载荷。 */
function install(sent: any[], parseResp: Record<string, unknown>) {
  const impl: typeof fetch = async (url, init) => {
    const u = String(url);
    if (u.includes('/agents/')) return jsonRes([{ id: 'a1', name: '测试Agent', role: '律师' }]);
    if (u.includes('/ollama/models')) return jsonRes([{ name: 'qwen3.8' }]);
    if (u.includes('/sessions?')) return jsonRes([{ id: 's1', title: '会话1', message_count: 1 }]);
    if (u.includes('/messages')) return jsonRes([]);
    if (u.includes('/attachments/parse')) return jsonRes(parseResp);
    if (u.includes('/ollama/chat/stream')) {
      try { sent.push(JSON.parse(String(init?.body ?? '{}'))); } catch { /* 忽略非法 body */ }
      return sseRes([tokenEvent('ok'), doneEvent('ok')]);
    }
    return jsonRes([]);
  };
  vi.spyOn(globalThis, 'fetch').mockImplementation(impl);
}

function getTextarea(): HTMLTextAreaElement {
  const el = document.querySelector('textarea');
  if (!el) throw new Error('未找到输入框 textarea');
  return el as HTMLTextAreaElement;
}
function getSendButton(): HTMLElement {
  const btns = Array.from(document.querySelectorAll('button')) as HTMLElement[];
  const hit = btns.find(b => b.getAttribute('data-tip') === '发送');
  if (!hit) throw new Error('未找到发送按钮');
  return hit;
}
function getFileInput(): HTMLInputElement {
  const el = document.querySelector('input[type="file"]') as HTMLInputElement | null;
  if (!el) throw new Error('未找到文件输入框');
  return el;
}

/** 驱动一次真实上传：造 File → 注入 input.files → 触发 change → 等解析落地。 */
async function uploadFile(name = '借条.pdf') {
  const file = new File([new Uint8Array([0x25, 0x50, 0x44, 0x46])], name, { type: 'application/pdf' });
  const input = getFileInput();
  await act(async () => {
    Object.defineProperty(input, 'files', { value: [file], configurable: true });
    input.dispatchEvent(new Event('change', { bubbles: true }));
  });
  // 等 FileReader.onload + /attachments/parse 响应 + setPendingItems 落地
  await new Promise(r => setTimeout(r, 250));
}

beforeEach(() => { vi.restoreAllMocks(); localStorage.clear(); });

describe('表#6 附件走路径（拉模式）', () => {
  it('T1 有 savedPath → 正文含路径与 read_file 指令，且不含解析全文', async () => {
    localStorage.setItem('subagent_messages_v4', JSON.stringify({ s1: [] }));
    const sent: any[] = [];
    install(sent, { name: '借条.pdf', kind: 'pdf', text: PARSED_TEXT,
                    truncated: false, saved_path: SAVED_PATH, save_error: null });

    const { unmount } = render(<ChatPanel projectId="p1" agentId="a1" />);
    await waitFor(() => expect(getTextarea()).toBeTruthy(), { timeout: 3000 });
    await uploadFile();

    fireEvent.change(getTextarea(), { target: { value: '请分析这份借条' } });
    await act(async () => { fireEvent.click(getSendButton()); });
    await waitFor(() => expect(sent.length).toBeGreaterThan(0), { timeout: 3000 });

    const msgs = sent[sent.length - 1].messages || [];
    const user = [...msgs].reverse().find((m: any) => m.role === 'user');
    const content = String(user?.content || '');

    // ⛔ 核心断言：路径在、全文不在
    expect(content).toContain(SAVED_PATH);
    expect(content).toContain('read_file');
    expect(content).not.toContain(PARSED_TEXT);
    // 探针的前缀也不得出现（防止只截断而仍注入部分内容）
    expect(content).not.toContain('借条正文探针XYZ');
    // 用户原话保留
    expect(content).toContain('请分析这份借条');
    // 文件名仍在（用户/agent 都要知道是哪个文件）
    expect(content).toContain('借条.pdf');
    unmount();
  });

  it('T2 无 savedPath → 退回全额注入（不得让用户失去让 agent 看到文件的能力）', async () => {
    localStorage.setItem('subagent_messages_v4', JSON.stringify({ s1: [] }));
    const sent: any[] = [];
    // saved_path 为 null：模拟会话未创建 / 后端落盘失败
    install(sent, { name: '借条.pdf', kind: 'pdf', text: PARSED_TEXT,
                    truncated: false, saved_path: null, save_error: 'OSError: 磁盘只读' });

    const { unmount } = render(<ChatPanel projectId="p1" agentId="a1" />);
    await waitFor(() => expect(getTextarea()).toBeTruthy(), { timeout: 3000 });
    await uploadFile();

    fireEvent.change(getTextarea(), { target: { value: '请看借条' } });
    await act(async () => { fireEvent.click(getSendButton()); });
    await waitFor(() => expect(sent.length).toBeGreaterThan(0), { timeout: 3000 });

    const msgs = sent[sent.length - 1].messages || [];
    const user = [...msgs].reverse().find((m: any) => m.role === 'user');
    const content = String(user?.content || '');

    // ⛔ 退化路径：全文必须在（这是本需求的反向守护，防"只传路径"改过头）
    expect(content).toContain(PARSED_TEXT);
    expect(content).toContain('未能落盘');
    expect(content).toContain('请看借条');
    unmount();
  });

  it('T3 解析失败但有路径 → 仍给路径（agent 可自行决定读不读）', async () => {
    localStorage.setItem('subagent_messages_v4', JSON.stringify({ s1: [] }));
    const sent: any[] = [];
    // text=null：后端解析不出（如扫描件），但已落盘
    install(sent, { name: '扫描件.pdf', kind: 'pdf', text: null,
                    truncated: false, saved_path: SAVED_PATH, save_error: null });

    const { unmount } = render(<ChatPanel projectId="p1" agentId="a1" />);
    await waitFor(() => expect(getTextarea()).toBeTruthy(), { timeout: 3000 });
    await uploadFile('扫描件.pdf');

    fireEvent.change(getTextarea(), { target: { value: '这是什么' } });
    await act(async () => { fireEvent.click(getSendButton()); });
    await waitFor(() => expect(sent.length).toBeGreaterThan(0), { timeout: 3000 });

    const msgs = sent[sent.length - 1].messages || [];
    const user = [...msgs].reverse().find((m: any) => m.role === 'user');
    const content = String(user?.content || '');

    expect(content).toContain(SAVED_PATH);
    expect(content).toContain('read_file');
    expect(content).toContain('扫描件.pdf');
    unmount();
  });

  it('T4 用户原话不被附件段污染（正文以原话开头）', async () => {
    localStorage.setItem('subagent_messages_v4', JSON.stringify({ s1: [] }));
    const sent: any[] = [];
    install(sent, { name: '借条.pdf', kind: 'pdf', text: PARSED_TEXT,
                    truncated: false, saved_path: SAVED_PATH, save_error: null });

    const { unmount } = render(<ChatPanel projectId="p1" agentId="a1" />);
    await waitFor(() => expect(getTextarea()).toBeTruthy(), { timeout: 3000 });
    await uploadFile();

    const raw = '第一行诉求\n第二行补充';
    fireEvent.change(getTextarea(), { target: { value: raw } });
    await act(async () => { fireEvent.click(getSendButton()); });
    await waitFor(() => expect(sent.length).toBeGreaterThan(0), { timeout: 3000 });

    const msgs = sent[sent.length - 1].messages || [];
    const user = [...msgs].reverse().find((m: any) => m.role === 'user');
    const content = String(user?.content || '');

    // 用户原话在最前、换行保真（B1 契约未被本次改动破坏）
    expect(content.startsWith(raw)).toBe(true);
    expect(content).toContain('第一行诉求\n第二行补充');
    // ⛔ 附件段必须接在原话**之后**，不得插进原话中间（原写法曾用恒真断言，测不出东西）
    expect(content).toContain('--- 附件内容 ---');
    expect(content.indexOf('--- 附件内容 ---')).toBeGreaterThan(raw.length);
    expect(content.slice(raw.length)).toContain(SAVED_PATH);
    unmount();
  });

  it('T5 源码层：旧的"全文注入"写法已不存在（防回潮）', async () => {
    const src = await import('../panels/ChatPanel?raw').then(m => (m as any).default as string);
    // ⛔ 旧写法特征：有路径时仍把 parsedText 拼进正文
    expect(src.includes('return f.parsedText ? `${head}\\n${f.parsedText}`')).toBe(false);
    // 新写法特征：拉模式的读取指令必须在
    expect(src.includes('原件已保存')).toBe(true);
    expect(src.includes('请用 read_file 读取上述绝对路径')).toBe(true);
    // 退化路径必须在（无路径时全额注入）
    expect(src.includes('原件未能落盘，故全文随消息附上')).toBe(true);
    // ⛔ ATTACH_MARK 仍保留（分隔标记，早于折叠功能存在）
    expect(src.includes("const ATTACH_MARK = '--- 附件内容 ---'")).toBe(true);
  });
});
