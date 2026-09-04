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
 * API base resolution — no hardcoded 8765/11434 in the UI.
 *
 * Priority:
 *   1. localStorage 'subagent_api_base'  (set by SettingsPanel, survives reload)
 *   2. window.__SUBAGENT__ injected by Electron main.js (read from config.json)
 *   3. fallback 127.0.0.1:8765 (dev default, matches config.json default)
 *
 * `resolveApiBase()` is async so it can consult the sidecar once to learn the
 * real sidecar_port if the user changed it in config.json.
 */

const LS_KEY = 'subagent_api_base';

export interface SubagentInject {
  sidecarHost?: string;
  sidecarPort?: number;
  ollamaBaseUrl?: string;
  dataRoot?: string;
  defaultModel?: string;
  configPath?: string;
}

export function getInjected(): SubagentInject {
  // Electron main.js sets this before the window loads.
  return (window as any).__SUBAGENT__ || {};
}

export function getApiBase(): string {
  const stored = localStorage.getItem(LS_KEY);
  if (stored) return stored.replace(/\/$/, '');
  const inj = getInjected();
  if (inj.sidecarHost && inj.sidecarPort) {
    return `http://${inj.sidecarHost}:${inj.sidecarPort}/api`;
  }
  return 'http://127.0.0.1:8765/api';
}

export function setApiBase(url: string): void {
  localStorage.setItem(LS_KEY, url.replace(/\/$/, ''));
}

/** Ask the sidecar for its config; returns { ok, base?, config? } */
export async function probeConfig(currentBase: string): Promise<{ ok: boolean; config?: any; base?: string }> {
  try {
    const r = await fetch(`${currentBase}/config`, { signal: AbortSignal.timeout(2500) });
    if (!r.ok) return { ok: false };
    const cfg = await r.json();
    return { ok: true, config: cfg, base: currentBase };
  } catch {
    return { ok: false };
  }
}
