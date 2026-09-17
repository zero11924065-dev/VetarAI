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
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { render, waitFor, fireEvent, act } from '@testing-library/react';
import React from 'react';
import { ChatPanel, isAudioFile, encodeWavPcm16 } from '../panels/ChatPanel';

import { jsonRes, sseRes, tokenEvent, doneEvent } from './helpers/fetchMock';

/**
 * 0.4.29（P3）· ASR 语音转写双场景前端链路。
 *
 * 被测机制：
 *   ① 上传录音文件：暂存区占位（转写中）→ webUtils.getPathForFile 拿绝对路径 →
 *      POST /api/asr/transcribe（带 project/session 归属让后端复制落盘）→ 填 transcript；
 *   ② 会话内录音：MediaRecorder → webm → Web Audio 转 16k WAV → 入暂存区 →
 *      同一条转写链（无 File 句柄，走 attachments/parse base64 落盘兜底）。
 *
 * 关键契约（本文件的断言对象）：
 *   - 音频不读 base64 进暂存区（路径模式优先，10MB 上限仅兜底通道适用）；
 *   - 转写失败必须可见可重试，绝不静默吞；
 *   - 发给模型的载荷必含 [🎤 标记与转写文稿（agent 的 read_file 读不出音频，
 *     文稿不内联等于 agent 永远听不到这段语音）；
 *   - parse 兜底通道已落盘的，transcribe 不再带归属（防重复复制）。
 *
 * 覆盖：
 *   A1 文件选择器 accept 含音频扩展名（入口可达性）
 *   A2 路径模式：getPathForFile → transcribe 带归属 → 已转写 → 载荷含文稿与路径
 *   A3 转写失败 → 失败态可见 → 重试（File 句柄已丢，靠 originPath）→ 成功
 *   A4 无 getPathForFile → parse 兜底：transcribe 用 saved_path 且不带归属
 *   A5 录音链：mic 按钮 → 录音态 → 停止 → 暂存区「录音-」项 → transcribe 被调
 *   A6 仅音频无文本可发送（发送闸门把音频算作有效内容）
 *   A7 纯函数：isAudioFile 判别 / encodeWavPcm16 头字节与采样率
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

const PROBE = '转写探针文本QWE：今天下午三点会议室讨论模型包验收。';
const ABS_PATH = '/Users/vetar/recordings/voice.wav';

interface MockBag {
  sent: any[];
  transcribeBodies: any[];
  parseBodies: any[];
}

/** 安装 fetch 桩：转写/解析/流式全捕获；transcribeFailFirst 用于 A3 先败后成。 */
function install(bag: MockBag, opts: { transcribeFailFirst?: boolean } = {}) {
  let transcribeCalls = 0;
  const impl: typeof fetch = async (url, init) => {
    const u = String(url);
    if (u.includes('/agents/')) return jsonRes([{ id: 'a1', name: '测试Agent', role: '助手' }]);
    if (u.includes('/ollama/models')) return jsonRes([{ name: 'qwen3.8' }]);
    if (u.includes('/sessions?')) return jsonRes([{ id: 's1', title: '会话1', message_count: 1 }]);
    if (u.includes('/messages')) return jsonRes([]);
    if (u.includes('/asr/transcribe')) {
      transcribeCalls++;
      try { bag.transcribeBodies.push(JSON.parse(String(init?.body ?? '{}'))); } catch { /* 忽略 */ }
      if (opts.transcribeFailFirst && transcribeCalls === 1) {
        return jsonRes({ detail: '未安装启用的 ASR 模型包' }, 409);
      }
      return jsonRes({ text: PROBE, duration_s: 1.2, model_pack_id: 'sensevoice-small-onnx',
                       saved_path: '/saved/voice.wav', save_error: null });
    }
    if (u.includes('/attachments/parse')) {
      try { bag.parseBodies.push(JSON.parse(String(init?.body ?? '{}'))); } catch { /* 忽略 */ }
      return jsonRes({ name: 'voice.wav', kind: 'audio', text: null,
                       saved_path: '/parse-saved/voice.wav', save_error: null });
    }
    if (u.includes('/ollama/chat/stream')) {
      try { bag.sent.push(JSON.parse(String(init?.body ?? '{}'))); } catch { /* 忽略 */ }
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

/** 驱动一次音频上传：造 File → 注入 input.files → 触发 change。 */
async function uploadAudio(name = 'voice.wav') {
  const file = new File([new Uint8Array([0x52, 0x49, 0x46, 0x46])], name, { type: 'audio/wav' });
  const input = getFileInput();
  await act(async () => {
    Object.defineProperty(input, 'files', { value: [file], configurable: true });
    input.dispatchEvent(new Event('change', { bubbles: true }));
  });
}

beforeEach(() => { vi.restoreAllMocks(); localStorage.clear(); });
afterEach(() => {
  delete (window as any).subagent;
  delete (globalThis as any).MediaRecorder;
  delete (window as any).AudioContext;
  delete (window as any).OfflineAudioContext;
});

describe('0.4.29 P3 ASR 语音转写双场景', () => {
  it('A1 文件选择器 accept 含音频扩展名（入口可达性）', async () => {
    localStorage.setItem('subagent_messages_v4', JSON.stringify({ s1: [] }));
    const bag: MockBag = { sent: [], transcribeBodies: [], parseBodies: [] };
    install(bag);
    const { unmount } = render(<ChatPanel projectId="p1" agentId="a1" />);
    await waitFor(() => expect(getTextarea()).toBeTruthy(), { timeout: 3000 });

    const accept = getFileInput().getAttribute('accept') || '';
    for (const ext of ['.wav', '.mp3', '.m4a', '.aac', '.aiff', '.caf', '.flac', '.ogg', '.opus', '.webm']) {
      expect(accept).toContain(ext);
    }
    unmount();
  });

  it('A2 路径模式：getPathForFile → transcribe 带归属 → 已转写 → 载荷含文稿', async () => {
    localStorage.setItem('subagent_messages_v4', JSON.stringify({ s1: [] }));
    (window as any).subagent = { getPathForFile: () => ABS_PATH };
    const bag: MockBag = { sent: [], transcribeBodies: [], parseBodies: [] };
    install(bag);

    const { unmount, container } = render(<ChatPanel projectId="p1" agentId="a1" />);
    await waitFor(() => expect(getTextarea()).toBeTruthy(), { timeout: 3000 });
    // 等会话列表加载完成（currentSessionId 就绪），否则 transcribe 拿不到归属——
    // 真实场景同样存在该竞速，测试按「会话就绪后再拖文件」的正常时序走
    await new Promise(r => setTimeout(r, 300));
    await uploadAudio();

    // 暂存区三态终点：已转写
    await waitFor(() => expect(container.textContent).toContain('已转写'), { timeout: 3000 });
    // 路径模式：直传绝对路径，带 project/session 归属（后端据此复制落盘）
    expect(bag.transcribeBodies.length).toBe(1);
    expect(bag.transcribeBodies[0].path).toBe(ABS_PATH);
    expect(bag.transcribeBodies[0].project_id).toBe('p1');
    expect(bag.transcribeBodies[0].session_id).toBe('s1');
    // 路径模式不得走 base64 parse 兜底
    expect(bag.parseBodies.length).toBe(0);

    fireEvent.change(getTextarea(), { target: { value: '这段语音说了什么' } });
    await act(async () => { fireEvent.click(getSendButton()); });
    await waitFor(() => expect(bag.sent.length).toBeGreaterThan(0), { timeout: 3000 });

    const msgs = bag.sent[bag.sent.length - 1].messages || [];
    const user = [...msgs].reverse().find((m: any) => m.role === 'user');
    const content = String(user?.content || '');
    // 消息标记 + 转写文稿内联 + 原件路径溯源，三样缺一不可
    expect(content).toContain('[🎤 voice.wav]');
    expect(content).toContain(PROBE);
    expect(content).toContain('/saved/voice.wav');
    expect(content).toContain('这段语音说了什么');
    unmount();
  });

  it('A3 转写失败可见可重试：失败态 → 点重试（靠 originPath）→ 成功', async () => {
    localStorage.setItem('subagent_messages_v4', JSON.stringify({ s1: [] }));
    (window as any).subagent = { getPathForFile: () => ABS_PATH };
    const bag: MockBag = { sent: [], transcribeBodies: [], parseBodies: [] };
    install(bag, { transcribeFailFirst: true });

    const { unmount, container } = render(<ChatPanel projectId="p1" agentId="a1" />);
    await waitFor(() => expect(getTextarea()).toBeTruthy(), { timeout: 3000 });
    await uploadAudio();

    // 失败态必须可见（绝不静默吞）
    await waitFor(() => expect(container.textContent).toContain('转写失败'), { timeout: 3000 });
    expect(bag.transcribeBodies.length).toBe(1);

    // 重试按钮：File 句柄在 change 处理后已丢，靠首次记下的 originPath 直传
    const retryBtn = container.querySelector('button[data-tip^="重试转写"]') as HTMLElement | null;
    expect(retryBtn).toBeTruthy();
    await act(async () => { fireEvent.click(retryBtn!); });

    await waitFor(() => expect(container.textContent).toContain('已转写'), { timeout: 3000 });
    expect(bag.transcribeBodies.length).toBe(2);
    expect(bag.transcribeBodies[1].path).toBe(ABS_PATH);
    unmount();
  });

  it('A4 无 getPathForFile（浏览器兜底）：parse 落盘 → transcribe 用 saved_path 不带归属', async () => {
    localStorage.setItem('subagent_messages_v4', JSON.stringify({ s1: [] }));
    // 故意不挂 window.subagent —— 模拟纯浏览器环境
    const bag: MockBag = { sent: [], transcribeBodies: [], parseBodies: [] };
    install(bag);

    const { unmount, container } = render(<ChatPanel projectId="p1" agentId="a1" />);
    await waitFor(() => expect(getTextarea()).toBeTruthy(), { timeout: 3000 });
    await uploadAudio();

    await waitFor(() => expect(container.textContent).toContain('已转写'), { timeout: 3000 });
    // 兜底通道：先 base64 落盘
    expect(bag.parseBodies.length).toBe(1);
    expect(bag.parseBodies[0].name).toBe('voice.wav');
    // transcribe 用 parse 落盘路径；parse 已落盘 → 不再带归属（防重复复制）
    expect(bag.transcribeBodies.length).toBe(1);
    expect(bag.transcribeBodies[0].path).toBe('/parse-saved/voice.wav');
    expect(bag.transcribeBodies[0].project_id).toBe('');
    expect(bag.transcribeBodies[0].session_id).toBe('');
    unmount();
  });

  it('A5 录音链：mic 开始 → 录音态可见 → 停止 → 暂存区「录音-」项 → transcribe 被调', async () => {
    localStorage.setItem('subagent_messages_v4', JSON.stringify({ s1: [] }));
    const bag: MockBag = { sent: [], transcribeBodies: [], parseBodies: [] };
    install(bag);

    // jsdom 无录音/Web Audio 栈，全链路桩化（行为契约不变：stop 触发 onstop → 转换 → 暂存）
    const fakeStream = { getTracks: () => [{ stop: vi.fn() }] };
    Object.defineProperty(navigator, 'mediaDevices', {
      value: { getUserMedia: vi.fn(async () => fakeStream) }, configurable: true,
    });
    (globalThis as any).MediaRecorder = class {
      static isTypeSupported() { return true; }
      ondataavailable: ((e: any) => void) | null = null;
      onstop: (() => void) | null = null;
      constructor(_stream: any, _opts?: any) {}
      start() {}
      stop() {
        this.ondataavailable?.({ data: new Blob([new Uint8Array([1, 2, 3])], { type: 'audio/webm' }) });
        this.onstop?.();
      }
    };
    (window as any).AudioContext = class {
      async decodeAudioData(_buf: ArrayBuffer) { return { duration: 0.1 }; }
      async close() {}
    };
    (window as any).OfflineAudioContext = class {
      destination = {};
      constructor(_ch: number, _frames: number, _rate: number) {}
      createBufferSource() { return { buffer: null, connect: vi.fn(), start: vi.fn() }; }
      async startRendering() { return { getChannelData: () => new Float32Array(1600) }; }
    };

    const { unmount, container } = render(<ChatPanel projectId="p1" agentId="a1" />);
    await waitFor(() => expect(getTextarea()).toBeTruthy(), { timeout: 3000 });

    const micBtn = container.querySelector('button[data-tip="语音输入（录音后自动转文字）"]') as HTMLElement | null;
    expect(micBtn).toBeTruthy();
    await act(async () => { fireEvent.click(micBtn!); });
    // 录音态可见（红色计时文案）
    await waitFor(() => expect(container.textContent).toContain('录音中'), { timeout: 3000 });

    const stopBtn = container.querySelector('button[data-tip="停止录音"]') as HTMLElement | null;
    expect(stopBtn).toBeTruthy();
    await act(async () => { fireEvent.click(stopBtn!); });

    // 停止后：webm → 16k WAV → 暂存区出现「录音-」前缀音频项，并走上转写链
    await waitFor(() => expect(container.textContent).toContain('录音-'), { timeout: 3000 });
    await waitFor(() => expect(bag.transcribeBodies.length).toBe(1), { timeout: 3000 });
    // 录音 blob 无本地路径 → 走 parse 兜底落盘
    expect(bag.parseBodies.length).toBe(1);
    expect(String(bag.parseBodies[0].name)).toContain('录音-');
    expect(String(bag.parseBodies[0].name)).toContain('.wav');
    unmount();
  });

  it('A6 仅音频无文本可发送（发送闸门把音频算作有效内容）', async () => {
    localStorage.setItem('subagent_messages_v4', JSON.stringify({ s1: [] }));
    (window as any).subagent = { getPathForFile: () => ABS_PATH };
    const bag: MockBag = { sent: [], transcribeBodies: [], parseBodies: [] };
    install(bag);

    const { unmount, container } = render(<ChatPanel projectId="p1" agentId="a1" />);
    await waitFor(() => expect(getTextarea()).toBeTruthy(), { timeout: 3000 });
    await uploadAudio();
    await waitFor(() => expect(container.textContent).toContain('已转写'), { timeout: 3000 });

    // 不输入任何文字，直接发送
    await act(async () => { fireEvent.click(getSendButton()); });
    await waitFor(() => expect(bag.sent.length).toBeGreaterThan(0), { timeout: 3000 });

    const msgs = bag.sent[bag.sent.length - 1].messages || [];
    const user = [...msgs].reverse().find((m: any) => m.role === 'user');
    const content = String(user?.content || '');
    expect(content).toContain('[🎤 voice.wav]');
    expect(content).toContain(PROBE);
    unmount();
  });

  it('A7 纯函数：isAudioFile 判别与 encodeWavPcm16 头字节', () => {
    expect(isAudioFile('a.wav', '')).toBe(true);
    expect(isAudioFile('a.MP3', '')).toBe(true);
    expect(isAudioFile('a.webm', '')).toBe(true);
    expect(isAudioFile('a.bin', 'audio/mpeg')).toBe(true);
    expect(isAudioFile('a.txt', 'text/plain')).toBe(false);
    expect(isAudioFile('a.pdf', 'application/pdf')).toBe(false);

    const samples = new Float32Array([0, 0.5, -0.5, 1, -1]);
    const blob = encodeWavPcm16(samples, 16000) as Blob & { arrayBuffer(): Promise<ArrayBuffer> };
    return blob.arrayBuffer().then(buf => {
      const v = new DataView(buf);
      // RIFF/WAVE 头、单声道、16bit、采样率 16000、数据段长度
      expect(String.fromCharCode(v.getUint8(0), v.getUint8(1), v.getUint8(2), v.getUint8(3))).toBe('RIFF');
      expect(String.fromCharCode(v.getUint8(8), v.getUint8(9), v.getUint8(10), v.getUint8(11))).toBe('WAVE');
      expect(v.getUint16(22, true)).toBe(1);
      expect(v.getUint16(34, true)).toBe(16);
      expect(v.getUint32(24, true)).toBe(16000);
      expect(v.getUint32(40, true)).toBe(10);
      expect(buf.byteLength).toBe(44 + 10);
    });
  });
});
