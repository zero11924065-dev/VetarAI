/**
 * styleAssert —— 样式断言助手（锚定意图而非具体色值）。
 *
 * ⛔ 为什么存在（A12，2026-09-13）：
 *   旧断言把主题色值硬编码进测试（如 `toContain('rgb(52, 199, 89)')`），
 *   UI 重构换令牌即误红——断言绑的是"写法"不是"意图"。
 *   意图是"这个元素用了 colors.ok / warnBg 这个语义色"，
 *   故断言应与 theme.ts 的令牌值联动，而不是钉死色值。
 *
 * jsdom 会把 hex 归一化为 `rgb(r, g, b)`（逗号后带空格）。
 */
export function hexToRgb(hex: string): string {
  const h = hex.replace('#', '');
  const r = parseInt(h.slice(0, 2), 16);
  const g = parseInt(h.slice(2, 4), 16);
  const b = parseInt(h.slice(4, 6), 16);
  return `rgb(${r}, ${g}, ${b})`;
}

/** 归一化：去空格 + 小写，便于同时接受 hex 与 rgb() 两种归一化形态。 */
export function normStyle(v: string): string {
  return v.toLowerCase().replace(/\s+/g, '');
}

/** 断言某个 jsdom 样式值等于指定主题色（hex 或 rgb 形态都接受）。 */
export function styleColorIs(actual: string, tokenHex: string): boolean {
  const a = normStyle(actual);
  return a === normStyle(tokenHex) || a.includes(normStyle(hexToRgb(tokenHex)));
}
