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
// 测试环境 setup：确保 localStorage 可用（jsdom 提供，但做防御性兜底）
import '@testing-library/jest-dom/vitest';

function makeStorage() {
  const d: Record<string,string> = {};
  return {
    getItem: (k:string) => (k in d ? d[k] : null),
    setItem: (k:string,v:string) => { d[k]=String(v); },
    removeItem: (k:string) => { delete d[k]; },
    clear: () => { for (const k in d) delete d[k]; },
    key: (i:number) => Object.keys(d)[i] ?? null,
    get length() { return Object.keys(d).length; },
  };
}
const st = makeStorage();
Object.defineProperty(globalThis, 'localStorage', { value: st, writable: true, configurable: true });
if (typeof window !== 'undefined') {
  Object.defineProperty(window, 'localStorage', { value: st, writable: true, configurable: true });
}

// jsdom 未实现 scrollIntoView → stub（渲染期 useEffect 调用）
if (typeof Element !== 'undefined' && !Element.prototype.scrollIntoView) {
  Element.prototype.scrollIntoView = function () { return undefined; };
}
