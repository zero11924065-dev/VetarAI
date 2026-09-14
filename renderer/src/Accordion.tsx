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
/**
 * A12 灵动批（0.4.25）：通用手风琴容器——展开/收起带高度过渡。
 *
 * 实现：CSS grid `grid-template-rows: 0fr ↔ 1fr` 过渡（内层 overflow:hidden），
 * 无需量高、无需第三方库。关闭时**延迟卸载内容**（动画播完再移除 DOM），
 * 展开时首帧 0fr、次帧 1fr，保证两个方向都有过渡。
 *
 * jsdom 兼容：测试环境可能没有 requestAnimationFrame，降级 setTimeout(0)。
 * 语义约束：本组件只做"延迟 200ms 卸载"，不改变子组件挂载期行为；
 *    有"收起后立即不在 textContent"硬契约的场景（如 B4 工具组自动收拢）
 *    不要直接套本组件——见 ToolStepsGroup 的折中实现注释。
 */
import { useEffect, useRef, useState } from 'react';

const raf = (cb: () => void): (() => void) => {
  if (typeof requestAnimationFrame === 'function') {
    let id2 = 0;
    const id1 = requestAnimationFrame(() => { id2 = requestAnimationFrame(cb); });
    return () => { cancelAnimationFrame(id1); if (id2) cancelAnimationFrame(id2); };
  }
  const t = setTimeout(cb, 0);
  return () => clearTimeout(t);
};

export function Accordion({ open, duration = 220, children }: {
  open: boolean;
  /** 过渡时长（ms）；关闭侧做同长的延迟卸载 */
  duration?: number;
  children: React.ReactNode;
}) {
  const [rendered, setRendered] = useState(open);
  const [shown, setShown] = useState(false);
  const timer = useRef<ReturnType<typeof setTimeout> | null>(null);

  useEffect(() => {
    if (open) {
      if (timer.current) { clearTimeout(timer.current); timer.current = null; }
      setRendered(true);
      // 次帧再置 shown：让 0fr → 1fr 过渡生效（同帧直置则跳过动画）
      return raf(() => setShown(true));
    }
    setShown(false);
    timer.current = setTimeout(() => setRendered(false), duration);
    return () => { if (timer.current) { clearTimeout(timer.current); timer.current = null; } };
  }, [open, duration]);

  if (!rendered) return null;
  return (
    <div style={{
      display: 'grid',
      gridTemplateRows: shown ? '1fr' : '0fr',
      transition: `grid-template-rows ${duration}ms cubic-bezier(.2,.8,.3,1)`,
    }}>
      <div style={{ overflow: 'hidden', minHeight: 0 }}>{children}</div>
    </div>
  );
}
