/**
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
import React, { useEffect, useState } from 'react';
import { createPortal } from 'react-dom';

/**
 * 0.4.5：全局 portal 悬停提示层（根治提示被裁切）。
 *
 * 问题（0.4.4 实测）：data-tip 的 CSS 伪元素提示会被其所在的滚动/溢出容器
 * （如左栏项目列表）裁切，导致底部按钮的提示"在下方根本看不到"。
 * 修复：提示改为渲染到 document.body 的 fixed 定位浮层，
 * 不被任何祖先容器的 overflow 裁切；自动翻转方向（下/上/右）避让屏幕边缘。
 *
 * 事件委托：监听 document 的 mouseover/mouseout，命中 [data-tip] 即显示，
 * 全部既有 data-tip / tip-right 元素自动受益，无需逐个改组件。
 */
interface TipState {
  text: string;
  x: number;
  y: number;
  variant: 'down' | 'up' | 'right';
}

export function TipPortal() {
  const [tip, setTip] = useState<TipState | null>(null);

  useEffect(() => {
    let current: Element | null = null;

    const show = (el: Element) => {
      const text = el.getAttribute('data-tip') || '';
      if (!text) return;
      const r = el.getBoundingClientRect();
      const isRight = el.classList.contains('tip-right');
      // 默认下方；下方空间不足（<34px）翻到上方；tip-right 走右侧
      let variant: TipState['variant'] = 'down';
      let x = r.left + r.width / 2;
      let y = r.bottom + 6;
      if (isRight) {
        variant = 'right';
        x = r.right + 8;
        y = r.top + r.height / 2;
      } else if (r.bottom + 40 > window.innerHeight) {
        variant = 'up';
        y = r.top - 6;
      }
      setTip({ text, x, y, variant });
    };

    const onOver = (e: MouseEvent) => {
      const el = (e.target as Element | null)?.closest?.('[data-tip]') || null;
      if (el && el !== current) {
        current = el;
        show(el);
      }
    };
    const onOut = (e: MouseEvent) => {
      const el = (e.target as Element | null)?.closest?.('[data-tip]') || null;
      if (el === current) {
        current = null;
        setTip(null);
      }
    };
    const hide = () => { current = null; setTip(null); };

    document.addEventListener('mouseover', onOver, true);
    document.addEventListener('mouseout', onOut, true);
    window.addEventListener('scroll', hide, true);   // 滚动时隐藏（位置失效）
    window.addEventListener('resize', hide);
    return () => {
      document.removeEventListener('mouseover', onOver, true);
      document.removeEventListener('mouseout', onOut, true);
      window.removeEventListener('scroll', hide, true);
      window.removeEventListener('resize', hide);
    };
  }, []);

  if (!tip) return null;

  const style: React.CSSProperties = {
    position: 'fixed',
    zIndex: 2000,
    padding: '3px 8px',
    borderRadius: 4,
    background: 'rgba(26, 26, 30, 0.92)',
    color: '#fff',
    fontSize: 11,
    lineHeight: 1.5,
    whiteSpace: 'nowrap',
    pointerEvents: 'none',
  };
  if (tip.variant === 'down') { style.left = tip.x; style.top = tip.y; style.transform = 'translateX(-50%)'; }
  else if (tip.variant === 'up') { style.left = tip.x; style.top = tip.y; style.transform = 'translate(-50%, -100%)'; }
  else { style.left = tip.x; style.top = tip.y; style.transform = 'translateY(-50%)'; }

  return createPortal(<div style={style}>{tip.text}</div>, document.body);
}
