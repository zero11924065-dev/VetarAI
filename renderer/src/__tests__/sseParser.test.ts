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
import { describe, it, expect } from 'vitest';
import { parseSSEChunk, SSEStreamParser } from '../lib/sseParser';

// 后端真实事件格式（app.py _sse_format）：event: X\ndata: {json}\n\n
const enc = (ev: string, data: object) => `event: ${ev}\ndata: ${JSON.stringify(data)}\n\n`;

describe('parseSSEChunk — 3 种 mock 流', () => {
  it('正常流：token + tool_call + tool_result + state + done', () => {
    const raw =
      enc('token', { delta: '目录' }) +
      enc('tool_call', { id: 'c1', name: 'list_dir', args: {}, status: 'running' }) +
      enc('tool_result', { id: 'c1', name: 'list_dir', ok: true, summary: '2 个条目', error: null }) +
      enc('state', { step: 1, max: 5, tokens_used: 673 }) +
      enc('done', { content: '完成', tool_calls: [] });
    const evs = parseSSEChunk(raw);
    expect(evs.map(e => e.event)).toEqual(['token','tool_call','tool_result','state','done']);
    expect(evs[0].data.delta).toBe('目录');
    expect(evs[2].data.ok).toBe(true);
    expect(evs[3].data.tokens_used).toBe(673);
    expect(evs[4].data.content).toBe('完成');
  });

  it('中途 error 流：前若干事件后 error 干净结束', () => {
    const raw =
      enc('token', { delta: '部分' }) +
      enc('tool_call', { id: 'x', name: 'read_file', args: { path: '../e' }, status: 'running' }) +
      enc('error', { detail: '达到最大轮次，已停止。' });
    const evs = parseSSEChunk(raw);
    expect(evs.length).toBe(3);
    expect(evs[2].event).toBe('error');
    expect(evs[2].data.detail).toContain('停止');
  });

  it('含 : ping 心跳 + 空行 → 心跳被忽略，事件序列不变', () => {
    const raw =
      ': ping\n\n' +
      enc('token', { delta: 'a' }) +
      ': ping\n\n' +
      enc('token', { delta: 'b' }) +
      '\n\n' +               // 纯空块
      enc('done', { content: 'ab', tool_calls: [] });
    const evs = parseSSEChunk(raw);
    expect(evs.map(e => e.event)).toEqual(['token','token','done']);
    expect(evs[0].data.delta + evs[1].data.delta).toBe('ab');
  });
});

describe('parseSSEChunk — 异常路径（DoD）', () => {
  it('坏 JSON → data.raw 而非抛异常', () => {
    const evs = parseSSEChunk('event: token\ndata: {bad json\n\n');
    expect(evs[0].event).toBe('token');
    expect(evs[0].data.raw).toBe('{bad json');
  });

  it('缺 event 行 → 默认 message', () => {
    const evs = parseSSEChunk('data: {"x":1}\n\n');
    expect(evs[0].event).toBe('message');
    expect(evs[0].data.x).toBe(1);
  });

  it('空 data → data:{}', () => {
    const evs = parseSSEChunk('event: state\n\ndata: \n\n');
    expect(evs.some(e => e.event === 'state')).toBe(true);
  });

  it('data 内 JSON 含换行（多行拼接）→ 正确还原', () => {
    const pretty = '{\n  "args": {\n    "path": "a"   \n  }\n}';
    // 模拟 data: 多行
    const raw = `event: tool_call\ndata: {\ndata:   "args": {"path":"a"}\ndata: }\n\n`;
    const evs = parseSSEChunk(raw);
    expect(evs[0].event).toBe('tool_call');
    expect(evs[0].data.args.path).toBe('a');
  });
});

describe('TS-102 B08/B16 — 空格与多字节边界', () => {
  it('B16: data: 双空格 → 解析成功', () => {
    const evs = parseSSEChunk('event: token\ndata:  {"a":1}\n\n');
    expect(evs[0].data.a).toBe(1);
    const evs2 = parseSSEChunk('event: token\ndata:    {"b":2}\n\n');
    expect(evs2[0].data.b).toBe(2);
  });

  it('B08: 中文/emoji 按字节分片（多字节边界切断）→ 解码无 \\uFFFD', () => {
    const text = enc('token', { delta: '天气分析🌤️' }) + enc('done', { content: '天气分析🌤️' });
    const bytes = new TextEncoder().encode(text);
    const p = new SSEStreamParser();
    const decoder = new TextDecoder();
    const deltas: string[] = [];
    // 每次喂 7 字节（故意不对齐多字节字符边界）
    for (let i = 0; i < bytes.length; i += 7) {
      const slice = bytes.slice(i, Math.min(i + 7, bytes.length));
      const isLast = i + 7 >= bytes.length;
      const chunk = decoder.decode(slice, { stream: !isLast });
      for (const e of p.push(chunk)) if (e.event === 'token') deltas.push(e.data.delta);
    }
    for (const e of p.flush()) if (e.event === 'token') deltas.push(e.data.delta);
    const joined = deltas.join('');
    expect(joined).toBe('天气分析🌤️');
    expect(joined.includes('\uFFFD')).toBe(false);
  });

  it('B08: CRLF 事件分隔（\\r\\n\\r\\n）同样正确分块', () => {
    const p = new SSEStreamParser();
    const evs = [
      ...p.push('event: token\r\ndata: {"delta":"a"}\r\n\r\n'),
      ...p.push('event: done\r\ndata: {"content":"a"}\r\n\r\n'),
    ];
    expect(evs.map(e => e.event)).toEqual(['token', 'done']);
  });
});

describe('SSEStreamParser — 增量分片边界', () => {
  it('事件被分片切断时跨 push 拼接仍解析正确', () => {
    const full = enc('token', { delta: 'hello' }) + enc('done', { content: 'hello', tool_calls: [] });
    const p = new SSEStreamParser();
    const out: string[] = [];
    // 切成 3 片，故意从 data JSON 中间切断
    const third = Math.floor(full.length / 3);
    const slices = [full.slice(0, third), full.slice(third, third*2), full.slice(third*2)];
    for (const s of slices) {
      for (const e of p.push(s)) out.push(e.event);
    }
    for (const e of p.flush()) out.push(e.event);
    expect(out).toEqual(['token','done']);
  });

  it('单次 push 含完整块 → 立即产出，残余留 buf', () => {
    const p = new SSEStreamParser();
    const evs = p.push(enc('token', { delta: 'x' }));
    expect(evs.map(e=>e.event)).toEqual(['token']);
    expect(p.flush()).toEqual([]);
  });
});
