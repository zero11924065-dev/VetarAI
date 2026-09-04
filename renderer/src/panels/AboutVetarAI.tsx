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
import React, { useEffect } from 'react';
import { APP_INFO } from '../appInfo';

/**
 * checkpoint-043（用户需求一）：「关于VetarAI」介绍弹窗。
 * 居中遮罩 + 居中卡片；介绍文案 4 行居中显示；点遮罩/关闭按钮/ESC 关闭。
 */
export function AboutVetarAI({ onClose }: { onClose: () => void }) {
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => { if (e.key === 'Escape') onClose(); };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [onClose]);

  return (
    <div
      onClick={onClose}
      style={{
        position: 'fixed', inset: 0, zIndex: 9999,
        background: 'rgba(0,0,0,.55)', display: 'flex',
        alignItems: 'center', justifyContent: 'center',
      }}
    >
      <div
        onClick={e => e.stopPropagation()}
        style={{
          width: 420, maxWidth: '90vw', background: '#1e1e32',
          border: '1px solid #3a3a5a', borderRadius: 12,
          padding: '36px 32px 30px', textAlign: 'center',
          boxShadow: '0 12px 40px rgba(0,0,0,.5)', position: 'relative',
        }}
      >
        <button
          onClick={onClose}
          style={{
            position: 'absolute', top: 10, right: 14,
            background: 'transparent', border: 'none', color: '#888',
            fontSize: 18, cursor: 'pointer',
          }}
        >✕</button>
        <div style={{ fontSize: 30, fontWeight: 700, color: '#fff', letterSpacing: 1 }}>
          {APP_INFO.name}
        </div>
        <div style={{ marginTop: 14, fontSize: 13, color: '#aab' }}>
          版本号：{APP_INFO.version}
        </div>
        <div style={{ marginTop: 22, fontSize: 14, color: '#dde', lineHeight: 1.7 }}>
          {APP_INFO.taglineCn}
        </div>
        <div style={{ marginTop: 4, fontSize: 12, color: '#889', fontStyle: 'italic' }}>
          {APP_INFO.taglineEn}
        </div>
      </div>
    </div>
  );
}
