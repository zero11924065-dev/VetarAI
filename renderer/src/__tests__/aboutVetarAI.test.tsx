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
import { render, screen, act } from '@testing-library/react';
import React from 'react';
import { AboutVetarAI } from '../panels/AboutVetarAI';
import { APP_INFO } from '../appInfo';

// checkpoint-043（用户需求一）：「关于VetarAI」弹窗测试
describe('关于VetarAI 介绍弹窗', () => {
  beforeEach(() => { vi.restoreAllMocks(); });

  it('渲染 4 行居中介绍文案（名称/版本号/中文/英文）', () => {
    render(<AboutVetarAI onClose={() => {}} />);
    expect(screen.getByText('VetarAI')).toBeTruthy();
    expect(screen.getByText(`版本号：${APP_INFO.version}`)).toBeTruthy();
    expect(screen.getByText('一款零生态基础的Agent工具')).toBeTruthy();
    expect(screen.getByText('An ecosystem-agnostic Agent tool.')).toBeTruthy();
  });

  it('版本号 = 0.4.2（用户指定）', () => {
    expect(APP_INFO.version).toBe('0.4.2');
  });

  it('点关闭按钮触发 onClose', () => {
    const onClose = vi.fn();
    render(<AboutVetarAI onClose={onClose} />);
    act(() => { screen.getByText('✕').click(); });
    expect(onClose).toHaveBeenCalledTimes(1);
  });

  it('点遮罩触发 onClose', () => {
    const onClose = vi.fn();
    const { container } = render(<AboutVetarAI onClose={onClose} />);
    const overlay = container.firstChild as HTMLElement;
    act(() => { overlay.click(); });
    expect(onClose).toHaveBeenCalledTimes(1);
  });

  it('ESC 键触发 onClose', () => {
    const onClose = vi.fn();
    render(<AboutVetarAI onClose={onClose} />);
    act(() => {
      window.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape' }));
    });
    expect(onClose).toHaveBeenCalledTimes(1);
  });

  it('点卡片内容不关闭（stopPropagation）', () => {
    const onClose = vi.fn();
    render(<AboutVetarAI onClose={onClose} />);
    act(() => { screen.getByText('VetarAI').click(); });
    expect(onClose).not.toHaveBeenCalled();
  });
});
