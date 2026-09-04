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
// checkpoint-051 UI 重设计：自定义弹窗（规范 §6.5）+ S2 建议落地。
// 提供命令式 API（confirmDialog / alertDialog），替换分散的 window.confirm/alert，
// 交互语义完全不变（仍是"确认/取消"），只是视觉换成亮色设计规范。
// 模块级单例挂载，无需在组件树包 Provider。
import React, { useEffect } from 'react';
import { createRoot, Root } from 'react-dom/client';
import { colors, radius, shadow, fonts, btnPrimary, btnSecondary } from './theme';
import { Icon } from './Icon';

type DialogKind = 'confirm' | 'alert';

interface DialogOptions {
  kind: DialogKind;
  title?: string;
  message: React.ReactNode;
  confirmText?: string;
  cancelText?: string;
  danger?: boolean;       // 确认按钮用危险色（删除类）
}

interface DialogState extends DialogOptions {
  resolve: (v: boolean) => void;
}

let current: DialogState | null = null;
let listeners: (() => void)[] = [];
let root: Root | null = null;
let host: HTMLDivElement | null = null;

function ensureMount() {
  if (root) return;
  host = document.createElement('div');
  document.body.appendChild(host);
  root = createRoot(host);
  const render = () => {
    root!.render(
      <>
        <DialogHost state={current} />
        <PromptHost state={promptCurrent} />
      </>
    );
  };
  listeners.push(render);
  render();
}

function openDialog(opts: DialogOptions): Promise<boolean> {
  ensureMount();
  return new Promise<boolean>((resolve) => {
    current = { ...opts, resolve };
    listeners.forEach((l) => l());
  });
}

/** 替换 window.confirm：返回 Promise<boolean>。danger=true 时确认按钮为红色（删除类）。 */
export function confirmDialog(opts: {
  title?: string; message: React.ReactNode;
  confirmText?: string; cancelText?: string; danger?: boolean;
}): Promise<boolean> {
  return openDialog({ kind: 'confirm', ...opts });
}

/** 替换 window.alert：单按钮提示。 */
export function alertDialog(opts: { title?: string; message: React.ReactNode; }): Promise<boolean> {
  return openDialog({ kind: 'alert', ...opts });
}

// ── promptDialog（替换 window.prompt，S2 落地最后一块）──
interface PromptState {
  title?: string;
  message?: React.ReactNode;
  defaultValue?: string;
  confirmText?: string;
  cancelText?: string;
  resolve: (v: string | null) => void;
}
let promptCurrent: PromptState | null = null;

export function promptDialog(opts: {
  title?: string; message?: React.ReactNode; defaultValue?: string;
  confirmText?: string; cancelText?: string;
}): Promise<string | null> {
  ensureMount();
  return new Promise<string | null>((resolve) => {
    promptCurrent = { ...opts, resolve };
    listeners.forEach((l) => l());
  });
}

function PromptHost({ state }: { state: PromptState | null }) {
  const [value, setValue] = React.useState('');
  React.useEffect(() => {
    if (state) setValue(state.defaultValue ?? '');
  }, [state]);

  if (!state) return null;
  const close = (v: string | null) => {
    const r = promptCurrent?.resolve;
    promptCurrent = null;
    listeners.forEach((l) => l());
    r?.(v);
  };

  return (
    <div
      onMouseDown={(e) => { if (e.target === e.currentTarget) close(null); }}
      style={{
        position: 'fixed', inset: 0, background: 'rgba(0,0,0,0.35)',
        zIndex: 9999, display: 'flex', alignItems: 'center', justifyContent: 'center',
        fontFamily: fonts.base,
      }}
    >
      <div role="dialog" aria-modal="true"
        style={{
          width: 400, maxWidth: '90vw', background: colors.bgCard,
          borderRadius: radius.l, boxShadow: shadow.l, padding: '20px 24px',
          color: colors.textPrimary,
        }}>
        {state.title && (
          <div style={{ fontSize: 14, fontWeight: 600, marginBottom: 12 }}>{state.title}</div>
        )}
        {state.message && (
          <div style={{ fontSize: 13, color: colors.textSecondary, lineHeight: 1.6, marginBottom: 12 }}>
            {state.message}
          </div>
        )}
        <input
          autoFocus value={value}
          onChange={(e) => setValue(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === 'Enter') close(value);
            if (e.key === 'Escape') close(null);
          }}
          className="ui-input"
          style={{
            width: '100%', height: 30, padding: '0 10px', boxSizing: 'border-box',
            background: colors.bgCard, border: `1px solid ${colors.borderStrong}`,
            borderRadius: radius.s, fontSize: 13, color: colors.textPrimary, fontFamily: fonts.base,
          }}
        />
        <div style={{ display: 'flex', justifyContent: 'flex-end', gap: 8, marginTop: 20 }}>
          <button className="ui-btn ui-btn-secondary" style={btnSecondary} onClick={() => close(null)}>
            {state.cancelText || '取消'}
          </button>
          <button className="ui-btn ui-btn-primary" style={btnPrimary} onClick={() => close(value)}>
            {state.confirmText || '确认'}
          </button>
        </div>
      </div>
    </div>
  );
}

function DialogHost({ state }: { state: DialogState | null }) {
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (!current) return;
      if (e.key === 'Escape') { close(false); }
      if (e.key === 'Enter') { close(true); }
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, []);

  if (!state) return null;

  const close = (v: boolean) => {
    const r = current?.resolve;
    current = null;
    listeners.forEach((l) => l());
    r?.(v);
  };

  const isConfirm = state.kind === 'confirm';
  const confirmBtnStyle: React.CSSProperties = state.danger
    ? { ...btnPrimary, background: colors.danger, color: '#FFFFFF' }
    : { ...btnPrimary };

  return (
    <div
      onMouseDown={(e) => { if (e.target === e.currentTarget) close(false); }}
      style={{
        position: 'fixed', inset: 0, background: 'rgba(0,0,0,0.35)',
        zIndex: 9999, display: 'flex', alignItems: 'center', justifyContent: 'center',
        fontFamily: fonts.base,
      }}
    >
      <div
        role="dialog" aria-modal="true"
        style={{
          width: 400, maxWidth: '90vw', background: colors.bgCard,
          borderRadius: radius.l, boxShadow: shadow.l, padding: '20px 24px',
          color: colors.textPrimary,
        }}
      >
        {state.title && (
          <div style={{ fontSize: 14, fontWeight: 600, marginBottom: state.message ? 12 : 0 }}>
            {state.title}
          </div>
        )}
        <div style={{ fontSize: 13, color: colors.textSecondary, lineHeight: 1.6, whiteSpace: 'pre-wrap', wordBreak: 'break-word' }}>
          {state.message}
        </div>
        <div style={{ display: 'flex', justifyContent: 'flex-end', gap: 8, marginTop: 20 }}>
          {isConfirm && (
            <button className="ui-btn ui-btn-secondary" style={btnSecondary} onClick={() => close(false)}>
              {state.cancelText || '取消'}
            </button>
          )}
          <button
            className={state.danger ? 'ui-btn ui-btn-danger' : 'ui-btn ui-btn-primary'}
            style={confirmBtnStyle}
            onClick={() => close(true)}
          >
            {state.confirmText || (isConfirm ? '确认' : '知道了')}
          </button>
        </div>
      </div>
    </div>
  );
}

export { Icon };
