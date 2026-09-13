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
import { getApiBase } from '../apiBase';

/** fetch + JSON + 错误 detail 归一：失败抛带 detail 的 Error（供调用点 catch 后 setX('失败: '+e.message)）。 */
export async function apiJson(path: string, init?: RequestInit): Promise<any> {
  const res = await fetch(`${getApiBase()}${path}`, init);
  const d = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error((d as any).detail || `HTTP ${res.status}`);
  return d;
}

/** 闪示通知：立即显示 msg，ms 后清除。⛔ 时长/文案一律由调用点传字面量，本 helper 不设默认值（数值冻结纪律）。 */
export function flash(setter: (v: string | null) => void, msg: string, ms: number): void {
  setter(msg);
  setTimeout(() => setter(null), ms);
}
