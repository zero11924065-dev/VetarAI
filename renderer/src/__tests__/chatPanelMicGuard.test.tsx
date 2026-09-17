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
import { ChatPanel, encodeWavPcm16, wavPcm16Rms, SILENCE_RMS_THRESHOLD } from '../panels/ChatPanel';
import { on, __resetEventsForTest } from '../events';
import { APP_OPEN_SETTINGS } from '../appEvents';

import { jsonRes } from './helpers/fetchMock';

/**
 * 0.4.30 实测修复批 · 麦克风权限链（W1）与 ASR 可用性守卫（W3）。
 *
 * 被测契约：
 *   W1 权限四分支（经 window.subagent 桥，对应 preload → 主进程 systemPreferences）：
 *     granted → 直接 getUserMedia；denied/restricted → 中文指引弹窗不再录音；
 *     not-determined → requestMicAccess 触发系统弹窗，按结果放行/拦截；
 *     无桥（纯浏览器等不支持环境）→ 跳过系统权限链，交给 getUserMedia 自身弹窗。
 *   W1 静音检测：录音转 16k WAV 后 PCM RMS < 阈值（全 0 流）→ 暂存区标红
 *     「未检测到声音」，**不进转写链**（0.4.29 实测静音被模型幻听成"그."）。
 *   W3 ASR 守卫（GET /api/asr/status，三态契约 mock）：
 *     available=false（none/disabled）→ 弹提醒层（文案用 message/兜底），
 *     带「去模型包面板」（emit APP_OPEN_SETTINGS model-packs）与「知道了」；
 *     上传音频文件走同一守卫（音频项不进暂存区）。
 *
 * 覆盖：
 *   S1 未安装（state=none）→ 弹窗文案=message，不录音、不转写
 *   S2 已禁用（state=disabled，message=null）→ 兜底文案引导启用
 *   S3 就绪（state=ready）→ 正常进入录音
 *   S4 上传音频遇未安装 → 弹窗 + 音频项不进暂存区 + 不发 transcribe
 *   S5 「去模型包面板」→ 广播 APP_OPEN_SETTINGS {section:'model-packs'}
 *   P1 granted / P2 denied / P3 not-determined→允许 / P4 not-determined→拒绝 / P5 无桥环境
 *   M1 全 0 PCM → 标红拦截；M2 有声 PCM → 放行；M3 wavPcm16Rms 纯函数
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

type AsrStatusMock = { available: boolean; state: string; pack_id: string | null; message: string | null };
const ASR_READY: AsrStatusMock = { available: true, state: 'ready', pack_id: 'sensevoice-small-onnx', message: null };

interface Bag { transcribeBodies: any[]; parseBodies: any[] }

/** 安装 fetch 桩：asrStatus=null 模拟旧后端（404）；否则按给定契约返回。 */
function install(bag: Bag, asrStatus: AsrStatusMock | null) {
  const impl: typeof fetch = async (url, init) => {
    const u = String(url);
    if (u.includes('/asr/status')) {
      return asrStatus ? jsonRes(asrStatus) : jsonRes({ detail: 'not found' }, 404);
    }
    if (u.includes('/agents/')) return jsonRes([{ id: 'a1', name: '测试Agent', role: '助手' }]);
    if (u.includes('/ollama/models')) return jsonRes([{ name: 'qwen3.8' }]);
    if (u.includes('/sessions?')) return jsonRes([{ id: 's1', title: '会话1', message_count: 1 }]);
    if (u.includes('/messages')) return jsonRes([]);
    if (u.includes('/asr/transcribe')) {
      try { bag.transcribeBodies.push(JSON.parse(String(init?.body ?? '{}'))); } catch { /* 忽略 */ }
      return jsonRes({ text: '转写探针文本QWE', duration_s: 1.0, model_pack_id: 'sensevoice-small-onnx',
                       saved_path: '/saved/voice.wav', save_error: null });
    }
    if (u.includes('/attachments/parse')) {
      try { bag.parseBodies.push(JSON.parse(String(init?.body ?? '{}'))); } catch { /* 忽略 */ }
      return jsonRes({ name: 'voice.wav', kind: 'audio', text: null,
                       saved_path: '/parse-saved/voice.wav', save_error: null });
    }
    return jsonRes([]);
  };
  vi.spyOn(globalThis, 'fetch').mockImplementation(impl);
}

/** 录音/Web Audio 全链路桩（jsdom 无实现）。silent=true 时给全 0 PCM（应被静音检测拦截）。 */
function installRecordingMocks(opts: { silent?: boolean } = {}) {
  const getUserMedia = vi.fn(async () => ({ getTracks: () => [{ stop: vi.fn() }] }));
  Object.defineProperty(navigator, 'mediaDevices', { value: { getUserMedia }, configurable: true });
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
    async startRendering() {
      return { getChannelData: () => opts.silent ? new Float32Array(1600) : new Float32Array(1600).fill(0.01) };
    }
  };
  return { getUserMedia };
}

/** 麦克风权限桥（window.subagent 上挂 W1 新增两函数；status='__none__' 表示不挂桥）。 */
function installMicBridge(status: 'granted' | 'denied' | 'not-determined' | '__none__', askResult = false) {
  if (status === '__none__') return { getStatus: null, ask: null };
  const getStatus = vi.fn(async () => status);
  const ask = vi.fn(async () => askResult);
  (window as any).subagent = { ...(window as any).subagent, getMicPermissionStatus: getStatus, requestMicAccess: ask };
  return { getStatus, ask };
}

function getMicBtn(): HTMLElement {
  const el = document.querySelector('button[data-tip="语音输入（录音后自动转文字）"]') as HTMLElement | null;
  if (!el) throw new Error('未找到话筒按钮');
  return el;
}
function getFileInput(): HTMLInputElement {
  const el = document.querySelector('input[type="file"]') as HTMLInputElement | null;
  if (!el) throw new Error('未找到文件输入框');
  return el;
}
/** 关掉残留的提醒层/权限弹窗（Dialog 是模块单例，不关会泄漏到下一用例）。 */
async function closeAnyDialog(buttonText: string) {
  const btn = Array.from(document.body.querySelectorAll('[role="dialog"] button'))
    .find(b => b.textContent === buttonText) as HTMLElement | undefined;
  if (btn) await act(async () => { fireEvent.click(btn); });
}
/** 录音中的用例收尾：停止并等 finishRecording 全链走完（显示「已转写」）。
 *  不等待就 unmount 的话，onstop→finishRecording 的异步尾巴会在**下一用例**里落地，
 *  用下一用例的 fetch 桩发起 transcribe —— 跨用例污染（本文件实测踩过）。 */
async function stopRecordingAndSettle(container: HTMLElement) {
  const stopBtn = container.querySelector('button[data-tip="停止录音"]') as HTMLElement | null;
  if (!stopBtn) return;
  await act(async () => { fireEvent.click(stopBtn); });
  await waitFor(() => expect(container.textContent).toContain('已转写'), { timeout: 3000 });
}

beforeEach(() => { vi.restoreAllMocks(); localStorage.clear(); __resetEventsForTest(); });
afterEach(async () => {
  await closeAnyDialog('知道了');
  delete (window as any).subagent;
  delete (globalThis as any).MediaRecorder;
  delete (window as any).AudioContext;
  delete (window as any).OfflineAudioContext;
});

describe('0.4.30 W3 ASR 可用性守卫（三态契约）', () => {
  it('S1 未安装（state=none）：点话筒弹提醒层，文案用 message，不录音不转写', async () => {
    const bag: Bag = { transcribeBodies: [], parseBodies: [] };
    install(bag, { available: false, state: 'none', pack_id: null, message: '未安装语音转写模型包，请先到「模型包」面板安装。' });
    const { getUserMedia } = installRecordingMocks();
    installMicBridge('granted');

    const { unmount, container } = render(<ChatPanel projectId="p1" agentId="a1" />);
    await waitFor(() => expect(document.querySelector('textarea')).toBeTruthy(), { timeout: 3000 });
    await act(async () => { fireEvent.click(getMicBtn()); });

    await waitFor(() => {
      expect(document.body.textContent).toContain('语音转写不可用');
      expect(document.body.textContent).toContain('未安装语音转写模型包，请先到「模型包」面板安装。');
      expect(document.body.textContent).toContain('去模型包面板');
      expect(document.body.textContent).toContain('知道了');
    }, { timeout: 3000 });
    // 拦截生效：未碰麦克风、未发起转写、未进入录音态
    expect(getUserMedia).not.toHaveBeenCalled();
    expect(bag.transcribeBodies.length).toBe(0);
    expect(container.textContent).not.toContain('录音中');
    await closeAnyDialog('知道了');
    unmount();
  });

  it('S2 已禁用（state=disabled，message=null）：兜底文案引导去启用', async () => {
    const bag: Bag = { transcribeBodies: [], parseBodies: [] };
    install(bag, { available: false, state: 'disabled', pack_id: 'sensevoice-small-onnx', message: null });
    installRecordingMocks();

    const { unmount } = render(<ChatPanel projectId="p1" agentId="a1" />);
    await waitFor(() => expect(document.querySelector('textarea')).toBeTruthy(), { timeout: 3000 });
    await act(async () => { fireEvent.click(getMicBtn()); });

    await waitFor(() => {
      expect(document.body.textContent).toContain('已安装但被禁用');
      expect(document.body.textContent).toContain('启用');
    }, { timeout: 3000 });
    await closeAnyDialog('知道了');
    unmount();
  });

  it('S3 就绪（state=ready）：正常进入录音', async () => {
    const bag: Bag = { transcribeBodies: [], parseBodies: [] };
    install(bag, ASR_READY);
    installRecordingMocks();

    const { unmount, container } = render(<ChatPanel projectId="p1" agentId="a1" />);
    await waitFor(() => expect(document.querySelector('textarea')).toBeTruthy(), { timeout: 3000 });
    await act(async () => { fireEvent.click(getMicBtn()); });
    await waitFor(() => expect(container.textContent).toContain('录音中'), { timeout: 3000 });
    await stopRecordingAndSettle(container);
    unmount();
  });

  it('S4 上传音频遇未安装：弹同一提醒层，音频项不进暂存区、不发 transcribe', async () => {
    const bag: Bag = { transcribeBodies: [], parseBodies: [] };
    install(bag, { available: false, state: 'none', pack_id: null, message: '未安装语音转写模型包。' });

    const { unmount, container } = render(<ChatPanel projectId="p1" agentId="a1" />);
    await waitFor(() => expect(document.querySelector('textarea')).toBeTruthy(), { timeout: 3000 });

    const file = new File([new Uint8Array([0x52, 0x49, 0x46, 0x46])], 'voice.wav', { type: 'audio/wav' });
    await act(async () => {
      Object.defineProperty(getFileInput(), 'files', { value: [file], configurable: true });
      getFileInput().dispatchEvent(new Event('change', { bubbles: true }));
    });

    await waitFor(() => expect(document.body.textContent).toContain('语音转写不可用'), { timeout: 3000 });
    await closeAnyDialog('知道了');
    // 音频项被拦在暂存区外（无转写中/已转写/失败任何一态），且未发转写请求
    expect(container.textContent).not.toContain('voice.wav');
    expect(bag.transcribeBodies.length).toBe(0);
    expect(bag.parseBodies.length).toBe(0);
    unmount();
  });

  it('S5 「去模型包面板」按钮：广播 APP_OPEN_SETTINGS 定位 model-packs 分区', async () => {
    const bag: Bag = { transcribeBodies: [], parseBodies: [] };
    install(bag, { available: false, state: 'none', pack_id: null, message: '未安装语音转写模型包。' });
    installRecordingMocks();
    const got: any[] = [];
    on(APP_OPEN_SETTINGS, (ev) => got.push(ev));

    const { unmount } = render(<ChatPanel projectId="p1" agentId="a1" />);
    await waitFor(() => expect(document.querySelector('textarea')).toBeTruthy(), { timeout: 3000 });
    await act(async () => { fireEvent.click(getMicBtn()); });
    await waitFor(() => expect(document.body.textContent).toContain('去模型包面板'), { timeout: 3000 });

    const gotoBtn = Array.from(document.body.querySelectorAll('[role="dialog"] button'))
      .find(b => b.textContent === '去模型包面板') as HTMLElement;
    expect(gotoBtn).toBeTruthy();
    await act(async () => { fireEvent.click(gotoBtn); });

    expect(got.length).toBe(1);
    expect(got[0]).toEqual({ section: 'model-packs' });
    unmount();
  });

  it('S6 旧后端（/asr/status 404）：fail-open 放行，不弹提醒层', async () => {
    const bag: Bag = { transcribeBodies: [], parseBodies: [] };
    install(bag, null);
    installRecordingMocks();

    const { unmount, container } = render(<ChatPanel projectId="p1" agentId="a1" />);
    await waitFor(() => expect(document.querySelector('textarea')).toBeTruthy(), { timeout: 3000 });
    await act(async () => { fireEvent.click(getMicBtn()); });
    await waitFor(() => expect(container.textContent).toContain('录音中'), { timeout: 3000 });
    expect(document.body.textContent).not.toContain('语音转写不可用');
    await stopRecordingAndSettle(container);
    unmount();
  });
});

describe('0.4.30 W1 麦克风权限四分支（asr 已就绪）', () => {
  it('P1 granted：直接 getUserMedia，不触发系统授权请求', async () => {
    const bag: Bag = { transcribeBodies: [], parseBodies: [] };
    install(bag, ASR_READY);
    const { getUserMedia } = installRecordingMocks();
    const { ask } = installMicBridge('granted');

    const { unmount, container } = render(<ChatPanel projectId="p1" agentId="a1" />);
    await waitFor(() => expect(document.querySelector('textarea')).toBeTruthy(), { timeout: 3000 });
    await act(async () => { fireEvent.click(getMicBtn()); });

    await waitFor(() => expect(container.textContent).toContain('录音中'), { timeout: 3000 });
    expect(getUserMedia).toHaveBeenCalledTimes(1);
    expect(ask).not.toHaveBeenCalled();
    await stopRecordingAndSettle(container);
    unmount();
  });

  it('P2 denied：中文指引弹窗（系统设置路径），不进入录音', async () => {
    const bag: Bag = { transcribeBodies: [], parseBodies: [] };
    install(bag, ASR_READY);
    const { getUserMedia } = installRecordingMocks();
    const { ask } = installMicBridge('denied');

    const { unmount, container } = render(<ChatPanel projectId="p1" agentId="a1" />);
    await waitFor(() => expect(document.querySelector('textarea')).toBeTruthy(), { timeout: 3000 });
    await act(async () => { fireEvent.click(getMicBtn()); });

    await waitFor(() => {
      expect(document.body.textContent).toContain('麦克风权限已被拒绝，请到 系统设置→隐私与安全性→麦克风 开启 VetarAI');
    }, { timeout: 3000 });
    expect(getUserMedia).not.toHaveBeenCalled();
    expect(ask).not.toHaveBeenCalled();   // denied 态不再触发系统弹窗（TCC 也不会再弹）
    expect(container.textContent).not.toContain('录音中');
    await closeAnyDialog('知道了');
    unmount();
  });

  it('P3 not-determined → 系统弹窗授权通过：放行录音', async () => {
    const bag: Bag = { transcribeBodies: [], parseBodies: [] };
    install(bag, ASR_READY);
    const { getUserMedia } = installRecordingMocks();
    const { ask } = installMicBridge('not-determined', true);

    const { unmount, container } = render(<ChatPanel projectId="p1" agentId="a1" />);
    await waitFor(() => expect(document.querySelector('textarea')).toBeTruthy(), { timeout: 3000 });
    await act(async () => { fireEvent.click(getMicBtn()); });

    await waitFor(() => expect(container.textContent).toContain('录音中'), { timeout: 3000 });
    expect(ask).toHaveBeenCalledTimes(1);
    expect(getUserMedia).toHaveBeenCalledTimes(1);
    await stopRecordingAndSettle(container);
    unmount();
  });

  it('P4 not-determined → 系统弹窗被拒绝：指引弹窗，不录音', async () => {
    const bag: Bag = { transcribeBodies: [], parseBodies: [] };
    install(bag, ASR_READY);
    const { getUserMedia } = installRecordingMocks();
    const { ask } = installMicBridge('not-determined', false);

    const { unmount, container } = render(<ChatPanel projectId="p1" agentId="a1" />);
    await waitFor(() => expect(document.querySelector('textarea')).toBeTruthy(), { timeout: 3000 });
    await act(async () => { fireEvent.click(getMicBtn()); });

    await waitFor(() => {
      expect(document.body.textContent).toContain('麦克风权限已被拒绝，请到 系统设置→隐私与安全性→麦克风 开启 VetarAI');
    }, { timeout: 3000 });
    expect(ask).toHaveBeenCalledTimes(1);
    expect(getUserMedia).not.toHaveBeenCalled();
    expect(container.textContent).not.toContain('录音中');
    await closeAnyDialog('知道了');
    unmount();
  });

  it('P5 不支持环境（无 Electron 桥）：跳过系统权限链，交给 getUserMedia', async () => {
    const bag: Bag = { transcribeBodies: [], parseBodies: [] };
    install(bag, ASR_READY);
    const { getUserMedia } = installRecordingMocks();
    installMicBridge('__none__');

    const { unmount, container } = render(<ChatPanel projectId="p1" agentId="a1" />);
    await waitFor(() => expect(document.querySelector('textarea')).toBeTruthy(), { timeout: 3000 });
    await act(async () => { fireEvent.click(getMicBtn()); });

    await waitFor(() => expect(container.textContent).toContain('录音中'), { timeout: 3000 });
    expect(getUserMedia).toHaveBeenCalledTimes(1);
    await stopRecordingAndSettle(container);
    unmount();
  });
});

describe('0.4.30 W1 静音检测（asr 已就绪 + 权限 granted）', () => {
  it('M1 全 0 PCM：暂存区标红「未检测到声音」，不进转写链', async () => {
    const bag: Bag = { transcribeBodies: [], parseBodies: [] };
    install(bag, ASR_READY);
    installRecordingMocks({ silent: true });
    installMicBridge('granted');

    const { unmount, container } = render(<ChatPanel projectId="p1" agentId="a1" />);
    await waitFor(() => expect(document.querySelector('textarea')).toBeTruthy(), { timeout: 3000 });
    await act(async () => { fireEvent.click(getMicBtn()); });
    await waitFor(() => expect(container.textContent).toContain('录音中'), { timeout: 3000 });

    const stopBtn = container.querySelector('button[data-tip="停止录音"]') as HTMLElement;
    await act(async () => { fireEvent.click(stopBtn); });

    await waitFor(() => {
      expect(container.textContent).toContain('录音-');
      expect(container.textContent).toContain('未检测到声音，请检查麦克风权限或输入设备');
    }, { timeout: 3000 });
    // 核心断言：静音录音绝不进转写链（防"그."式幻听结果发给模型）
    expect(bag.transcribeBodies.length).toBe(0);
    expect(bag.parseBodies.length).toBe(0);
    expect(container.textContent).not.toContain('转写中');
    unmount();
  });

  it('M2 有声 PCM：正常入暂存区并发起转写', async () => {
    const bag: Bag = { transcribeBodies: [], parseBodies: [] };
    install(bag, ASR_READY);
    installRecordingMocks({ silent: false });
    installMicBridge('granted');

    const { unmount, container } = render(<ChatPanel projectId="p1" agentId="a1" />);
    await waitFor(() => expect(document.querySelector('textarea')).toBeTruthy(), { timeout: 3000 });
    await act(async () => { fireEvent.click(getMicBtn()); });
    await waitFor(() => expect(container.textContent).toContain('录音中'), { timeout: 3000 });

    const stopBtn = container.querySelector('button[data-tip="停止录音"]') as HTMLElement;
    await act(async () => { fireEvent.click(stopBtn); });

    await waitFor(() => expect(container.textContent).toContain('已转写'), { timeout: 3000 });
    expect(bag.transcribeBodies.length).toBe(1);
    expect(container.textContent).not.toContain('未检测到声音');
    unmount();
  });

  it('M3 wavPcm16Rms 纯函数：全 0 → 0；0.01 满幅占比 → 约 328 LSB（>阈值 8）', async () => {
    const silence = encodeWavPcm16(new Float32Array(1600), 16000);
    expect(await wavPcm16Rms(silence)).toBe(0);
    const voice = encodeWavPcm16(new Float32Array(1600).fill(0.01), 16000);
    const rms = await wavPcm16Rms(voice);
    expect(rms).toBeGreaterThan(SILENCE_RMS_THRESHOLD);
    // 0.01 * 32767 ≈ 327.67 LSB（量级校验，防阈值/实现同错）
    expect(rms).toBeGreaterThan(300);
    expect(rms).toBeLessThan(360);
  });
});
