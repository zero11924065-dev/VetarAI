/**
 * readChatPanelSource —— 读取「对话区功能」的全部源码（锚定意图，而非锚定文件）。
 *
 * ⛔ 为什么存在（A12 加固，2026-09-13）：
 *   多个守护测试用 `import('../panels/ChatPanel?raw')` 做源码静态断言
 *   （C2 收敛出口计数、B12 计时器契约、B10C8Fold 防折叠回潮、F4 节流契约、
 *   W3 防过度修复、073 formatTime/completedDuration 契约）。
 *   这些断言的【意图】是守护"对话区功能的源码形态"，而不是守护
 *   "这些代码恰好都写在 ChatPanel.tsx 一个文件里"。
 *   A12 UI 深度重构允许把 ChatPanel 拆出 panels/chat/ 子模块 ——
 *   直接读单文件会在拆分后空转（读不到=误红或假绿）。
 *   本助手把"对话区源码"定义为：
 *     ChatPanel.tsx 本体 ＋ panels/chat/ 目录下全部 .ts/.tsx（若存在）。
 *   拆分前后断言都读到同一份"功能全集"，计数类断言（调用点=5 等）不失效。
 *
 * ⛔ 使用约束：断言仍必须锚定【真实代码形态】（正则/声明前缀），
 *   不得用裸文案子串（注释会误命中，C5 已踩过）。
 */
export async function readChatPanelSource(): Promise<string> {
  const main = await import('../../panels/ChatPanel?raw').then(
    (m) => (m as any).default as string,
  );
  // Vite 静态分析 import.meta.glob：目录不存在时返回 {}，不会抛错。
  const parts = import.meta.glob('../../panels/chat/*.{ts,tsx}', {
    query: '?raw',
    import: 'default',
    eager: true,
  }) as Record<string, string>;
  const extra = Object.keys(parts)
    .sort()
    .map((k) => parts[k])
    .join('\n');
  return main + '\n' + extra;
}
