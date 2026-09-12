/*
 * VetarAI - Local-first multi-agent orchestration application
 * Copyright (C) 2026 zero11924065-dev
 * GPL-3.0-or-later（见仓库 LICENSE）
 */
/**
 * A/B-2（0.4.23）专项：`ctxTokensAfterArchive` —— 移入知识仓库后重算上下文指示器。
 *
 * ═══ 治的是什么 ═══
 *
 * 用户 2026-09-12 报障：「右上方的 token 计数逻辑有误，不是累加，历史遗留问题，修复多次未成功。」
 * 用户随后澄清真实诉求：「我要的是实时展示当前会话内的上下占用，对话越多自然会越来越大，
 * 当我移走至知识仓库，本身已经不占用上下文空间了，肯定要重新计算当前的上下文占用才对。」
 * → ⛔ **语义本来就是对的**（顶栏是"当前上下文占用"，不是累计消耗），历次修复失败是因为
 *   **全在调估算精度，没人动过真正的成因**。
 *
 * 真成因：归档后原实现把后端真实字数 `ctx_chars` **置 0**，指示器随即退回纯前端启发式
 * （只数未归档 user/assistant 正文 ×0.6），而启发式**不含 system prompt 与工具声明**——
 * 实测 `tools_spec` 单独就 8433 字符 ≈ **5060 token**（18 个工具）。于是移入仓库后数字
 * **断崖式掉到远低于真实值**，直到下一轮 `state` 事件才跳回 → 用户看到数字忽大忽小。
 *
 * 修法：只扣掉**被归档消息自身的贡献**，保住 system prompt + 工具声明基线，
 * 同时仍满足"移入仓库即下降"。
 *
 * ═══ 为什么用纯函数单测（而不是渲染测试）═══
 *
 * 归档交互链是 勾选模式 → 浮动栏「移入知识仓库」→ 弹窗填标题/分类/关键词 → 提交，
 * 且要观察扣减结果必须先有 `state` 事件把 `ctx_chars` 灌进 ref —— 这要跑流式渲染，
 * 而本项目 jsdom 的可控流时序坑已踩三次（见 segmentBreakRealInject.test.tsx 头注）。
 * 故把计算抽成模块级纯函数直接单测：锚定意图、不依赖 DOM 时序。
 *
 * 运行：node node_modules/vitest/vitest.mjs run src/__tests__/ctxTokensAfterArchive.test.ts
 */
import { describe, it, expect } from 'vitest';
import { ctxTokensAfterArchive } from '../panels/ChatPanel';

const M = (id: number, content: string) => ({ id, content });

describe('ctxTokensAfterArchive 归档后上下文重算', () => {
  it('T1 扣掉被归档消息的贡献，保住基线（不再断崖归零）', () => {
    // 后端真实值含 system prompt + 工具声明 + 消息正文；这里 10000 字符代表总量
    const msgs = [M(1, 'x'.repeat(500)), M(2, 'y'.repeat(300)), M(3, 'z'.repeat(200))];
    const r = ctxTokensAfterArchive(10000, msgs, new Set([2]));
    // 只扣 id=2 的 300 字符 → 9700；token = round(9700*0.6) = 5820
    expect(r.nextCtxChars).toBe(9700);
    expect(r.nextTokenUsed).toBe(5820);
    // ⛔ 核心：绝不能像原实现那样掉到"只数未归档正文"的量级（800*0.6=480）
    expect(r.nextTokenUsed).toBeGreaterThan(1000);
  });

  it('T2 ⛔ 移入仓库后数字必须下降（用户明确要求：脱离上下文就该重新计算）', () => {
    const msgs = [M(1, 'a'.repeat(2000)), M(2, 'b'.repeat(2000))];
    const before = ctxTokensAfterArchive(20000, msgs, new Set());
    const after = ctxTokensAfterArchive(20000, msgs, new Set([1]));
    expect(after.nextCtxChars).toBeLessThan(before.nextCtxChars);
    expect(after.nextTokenUsed!).toBeLessThan(before.nextTokenUsed!);
  });

  it('T3 多条同时归档：逐条扣减', () => {
    const msgs = [M(1, 'x'.repeat(500)), M(2, 'y'.repeat(300)), M(3, 'z'.repeat(200))];
    const r = ctxTokensAfterArchive(10000, msgs, new Set([1, 3]));
    expect(r.nextCtxChars).toBe(10000 - 500 - 200);
    expect(r.nextTokenUsed).toBe(Math.round(9300 * 0.6));
  });

  it('T4 ⛔ 无后端真值（ctx_chars=0）→ 不做扣减、不硬写显示值（交回启发式兜底）', () => {
    // 会话刚加载、还没跑过任何一轮、从未收到 state 事件的情形。
    // 若在此扣减会得出 0 → 把原本启发式还能算出的值也清成 0，比原行为更糟。
    const msgs = [M(1, 'x'.repeat(500))];
    const r = ctxTokensAfterArchive(0, msgs, new Set([1]));
    expect(r.nextCtxChars).toBe(0);
    expect(r.nextTokenUsed).toBeNull();   // null = 不要硬写，交由估算 effect 重算
  });

  it('T5 ⛔ 扣到 0（极端：归档了几乎全部内容）→ 不硬显示 0', () => {
    const msgs = [M(1, 'x'.repeat(10000))];
    const r = ctxTokensAfterArchive(10000, msgs, new Set([1]));
    expect(r.nextCtxChars).toBe(0);
    expect(r.nextTokenUsed).toBeNull();
  });

  it('T6 扣减不得为负（Math.max 下限保护）', () => {
    // 归档消息正文比 ctx_chars 还大（理论不该发生，但防御）
    const msgs = [M(1, 'x'.repeat(99999))];
    const r = ctxTokensAfterArchive(1000, msgs, new Set([1]));
    expect(r.nextCtxChars).toBe(0);
    expect(r.nextCtxChars).toBeGreaterThanOrEqual(0);
    expect(r.nextTokenUsed).toBeNull();
  });

  it('T7 ⛔ 只扣被勾选的消息：未勾选的、以及非数字 id 的本地气泡都不动', () => {
    const msgs = [
      M(1, 'x'.repeat(500)),
      M(2, 'y'.repeat(300)),
      { id: 'local_123_1', content: 'w'.repeat(400) },   // 流式临时气泡（非数字 id）
      { id: 3, content: undefined as unknown as string }, // content 缺失
    ];
    const r = ctxTokensAfterArchive(10000, msgs, new Set([2, 999]));
    // 只扣 id=2 的 300；id=999 不在列表里；local_ 气泡与 content 缺失的都不计
    expect(r.nextCtxChars).toBe(9700);
  });

  it('T8 空勾选集合 → 数值不变（归档 0 条不该动指示器）', () => {
    const msgs = [M(1, 'x'.repeat(500))];
    const r = ctxTokensAfterArchive(10000, msgs, new Set());
    expect(r.nextCtxChars).toBe(10000);
    expect(r.nextTokenUsed).toBe(Math.round(10000 * 0.6));
  });

  it('T9 换算系数与顶栏一致（0.6，与 contextLimit 同口径）', () => {
    // ⛔ 这个系数同时出现在 estimateContextTokens（后端真值分支）与 state 事件处理，
    //   三处必须一致，否则归档前后数字会跳。此断言把它钉住。
    const msgs = [M(1, 'x'.repeat(1000))];
    const r = ctxTokensAfterArchive(1000, msgs, new Set());
    expect(r.nextTokenUsed).toBe(600);
  });
});
