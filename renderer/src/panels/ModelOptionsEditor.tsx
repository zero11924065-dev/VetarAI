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
 * 第 2 批（0.4.15）A2/A4：每模型推理参数编辑器。
 *
 * 参数清单与取值范围**必须与后端 `sidecar/ollama/infer_options.py` 的
 * `_PARAM_MAP` / `_PARAM_RANGE` 严格一致**。若前端允许配一个后端不认的参数或越界值，
 * 后端会在注入时**静默丢弃** → 用户看到"设了不生效"，这类缺陷极难排查。
 * 后端是权威源，改动任一侧都要同步另一侧。
 *
 * ⚠️ num_ctx 与性能（B7 联动）：num_ctx 越大，prefill（首 token 前的提示词编码）越慢，
 * 本地 30B/35B 模型上尤其明显。故 UI **不给默认值**（留空=不传=沿用模型自身默认），
 * 并在此明示该权衡，由用户自行决定。
 *
 * ⚠️ 两个后端支持的参数不同：OpenAI 兼容端**没有 num_ctx / top_k**，
 * 且 repeat_penalty→frequency_penalty、num_predict→max_tokens（映射在后端做）。
 * 故非 Ollama 后端时这两项显示为不可用并说明原因，而不是让用户填了再被静默丢弃。
 */
import React, { useState } from 'react';
import { colors, fonts, radius, typo, input, calloutStyle } from '../theme';
import { Icon } from '../Icon';

/** 参数定义：键=后端规范名（Ollama 风格），与 infer_options._PARAM_MAP 一致 */
interface ParamDef {
  key: string;
  label: string;
  /** 该参数在 OpenAI 兼容后端是否可用（与后端 _PARAM_MAP['openai_compatible'] 的 None 对应） */
  ollamaOnly?: boolean;
  kind: 'int' | 'float' | 'list';
  min?: number;
  max?: number;
  step?: number;
  hint: string;
  placeholder: string;
}

// 范围逐条对照后端 _PARAM_RANGE，勿单边修改
const PARAMS: ParamDef[] = [
  { key: 'num_ctx', label: '上下文窗口 num_ctx', ollamaOnly: true, kind: 'int', min: 256, max: 1048576,
    hint: '模型一次能处理的 token 上限。⚠️ 调大会显著拖慢首字（prefill），30B/35B 本地模型尤其明显；留空=用模型默认',
    placeholder: '如 8192' },
  { key: 'temperature', label: '随机性 temperature', kind: 'float', min: 0, max: 2, step: 0.1,
    hint: '越高越发散、越低越确定。留空=用模型默认', placeholder: '0.0 ~ 2.0' },
  { key: 'top_p', label: '核采样 top_p', kind: 'float', min: 0, max: 1, step: 0.05,
    hint: '累积概率截断。留空=用模型默认', placeholder: '0.0 ~ 1.0' },
  { key: 'top_k', label: 'top_k', ollamaOnly: true, kind: 'int', min: 1, max: 1000,
    hint: '每步只从概率最高的 K 个词里选。留空=用模型默认', placeholder: '如 40' },
  { key: 'repeat_penalty', label: '重复惩罚 repeat_penalty', kind: 'float', min: 0, max: 3, step: 0.05,
    hint: '>1 抑制重复。OpenAI 兼容后端会映射为 frequency_penalty。留空=用模型默认', placeholder: '如 1.1' },
  { key: 'num_predict', label: '最大生成 num_predict', kind: 'int', min: -2, max: 1048576,
    hint: '最多生成多少 token；-1=不限，-2=填满上下文。OpenAI 兼容后端映射为 max_tokens', placeholder: '如 2048 或 -1' },
  { key: 'seed', label: '随机种子 seed', kind: 'int',
    hint: '固定后可复现同样输出（用于排查"每次结果不一样"）。留空=随机', placeholder: '如 42' },
  { key: 'stop', label: '停止词 stop', kind: 'list',
    hint: '遇到这些字符串就停止生成，多个用英文逗号分隔。留空=不限制', placeholder: '如 </s>, 用户:' },
];

interface Props {
  cfg: any;
  busy: boolean;
  onSave: (patch: Record<string, any>) => Promise<void>;
  isOllama: boolean;
  /**
   * 不接收 models 列表：曾设计成"在本组件里放一个模型下拉来新增配置"，
   * 但那会把每个模型名**再渲染一遍**，导致 InferencePanel 的模型列表与下拉里
   * 出现两处同名文本 —— 既有测试 `getByText('qwen3.8')` 因此报
   * "Found multiple elements"。根因是 UI 设计冗余，不该改测试去迁就。
   * 改为：模型列表每行提供「参数」按钮就地配置（见 InferencePanel），
   * 本组件只负责编辑**已配置**的模型，展开项由父级受控传入。
   */
  focus?: string | null;
}

export function ModelOptionsEditor({ cfg, busy, onSave, isOllama, focus }: Props) {
  const mo: Record<string, Record<string, any>> = cfg.model_options || {};
  const configured = Object.keys(mo);
  const [expanded, setExpanded] = useState<string | null>(configured[0] ?? null);
  const [err, setErr] = useState<string | null>(null);

  // 父级点了某个模型的「参数」按钮 → 展开它（受控）
  React.useEffect(() => {
    if (focus && mo[focus]) setExpanded(focus);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [focus]);

  /** 校验单个值；合法返回收窄后的值，非法返回 undefined（并给出原因） */
  function coerce(def: ParamDef, raw: string): { ok: true; value: any } | { ok: false; why: string } {
    const t = raw.trim();
    if (t === '') return { ok: true, value: null };   // 空 = 删除该项（回落模型默认）
    if (def.kind === 'list') {
      const arr = t.split(',').map(x => x.trim()).filter(Boolean);
      return arr.length ? { ok: true, value: arr } : { ok: true, value: null };
    }
    const n = Number(t);
    if (!Number.isFinite(n)) return { ok: false, why: `${def.label} 必须是数字` };
    if (def.kind === 'int' && !Number.isInteger(n)) return { ok: false, why: `${def.label} 必须是整数` };
    if (def.min !== undefined && n < def.min) return { ok: false, why: `${def.label} 不得小于 ${def.min}` };
    if (def.max !== undefined && n > def.max) return { ok: false, why: `${def.label} 不得大于 ${def.max}` };
    return { ok: true, value: def.kind === 'int' ? n : n };
  }

  function valueToString(def: ParamDef, v: any): string {
    if (v === undefined || v === null) return '';
    if (def.kind === 'list') return Array.isArray(v) ? v.join(', ') : String(v);
    return String(v);
  }

  async function removeModel(name: string) {
    const next = { ...mo };
    delete next[name];
    setErr(null);
    await onSave({ model_options: next });
    if (expanded === name) setExpanded(Object.keys(next)[0] ?? null);
  }

  async function setParam(model: string, def: ParamDef, raw: string) {
    const r = coerce(def, raw);
    if (!r.ok) { setErr(r.why); return; }
    setErr(null);
    const cur = { ...(mo[model] || {}) };
    if (r.value === null) delete cur[def.key];      // 空值 = 移除该项，回落模型默认
    else cur[def.key] = r.value;
    await onSave({ model_options: { ...mo, [model]: cur } });
  }

  return (
    <div>
      {!isOllama && (
        <div style={{ ...calloutStyle('info'), marginBottom: 10 }}>
          <Icon name="info" size={15} style={{ flexShrink: 0 }} />
          <span>当前为 OpenAI 兼容后端：<b>num_ctx 与 top_k 不支持</b>（已置灰），
            repeat_penalty 会自动映射为 frequency_penalty、num_predict 映射为 max_tokens。</span>
        </div>
      )}

      {configured.length === 0 && (
        <div style={{ fontSize: 12, color: colors.textTertiary, marginBottom: 8 }}>
          （尚未为任何模型配置参数——不配置时完全沿用模型自身默认值，行为与升级前一致）
        </div>
      )}

      {configured.map(name => {
        const params = mo[name] || {};
        const open = expanded === name;
        const count = Object.keys(params).length;
        return (
          <div key={name} style={{ border: `1px solid ${colors.borderSubtle}`, borderRadius: radius.s,
            marginBottom: 8, background: colors.bgCard, overflow: 'hidden' }}>
            <div style={{ display: 'flex', alignItems: 'center', gap: 6, padding: '0 10px', height: 32,
              cursor: 'pointer' }} onClick={() => setExpanded(open ? null : name)}>
              <Icon name="sliders" size={13} style={{ color: colors.textTertiary, flexShrink: 0 }} />
              <span style={{ flex: 1, minWidth: 0, overflow: 'hidden', whiteSpace: 'nowrap',
                textOverflow: 'ellipsis', fontFamily: fonts.mono, fontSize: 13,
                color: colors.textPrimary }} title={name}>{name}</span>
              <span style={{ fontSize: 11, color: count ? colors.textSecondary : colors.textTertiary, flexShrink: 0 }}>
                {count ? `${count} 项已设` : '全部默认'}
              </span>
              <Icon name={open ? 'chevron-up' : 'chevron-down'} size={13}
                style={{ color: colors.textTertiary, flexShrink: 0 }} />
              <button className="ui-btn ui-btn-ghost ui-ico-danger" disabled={busy}
                onClick={e => { e.stopPropagation(); removeModel(name); }}
                style={{ background: 'transparent', border: 'none', cursor: 'pointer',
                  color: colors.textTertiary, padding: 2, flexShrink: 0 }}>
                <Icon name="trash" size={13} />
              </button>
            </div>

            {open && (
              <div style={{ padding: '10px 12px', borderTop: `1px solid ${colors.borderSubtle}` }}>
                {PARAMS.map(def => {
                  const disabled = !isOllama && !!def.ollamaOnly;
                  const val = valueToString(def, params[def.key]);
                  return (
                    <div key={def.key} style={{ marginBottom: 10, opacity: disabled ? 0.5 : 1 }}>
                      <div style={{ display: 'flex', alignItems: 'center', gap: 6, marginBottom: 3 }}>
                        <span style={{ fontSize: 12, color: colors.textPrimary }}>{def.label}</span>
                        {def.min !== undefined && (
                          <span style={{ ...typo.micro, color: colors.textTertiary }}>
                            （{def.min}~{def.max}）
                          </span>
                        )}
                        {disabled && (
                          <span style={{ ...typo.micro, color: colors.warnText }}>
                            该后端不支持
                          </span>
                        )}
                        {val && !disabled && (
                          <Icon name="check" size={11} style={{ color: colors.ok }} />
                        )}
                      </div>
                      <input className="ui-input" style={{ ...input, fontFamily: fonts.mono, fontSize: 12.5 }}
                        value={val} disabled={busy || disabled}
                        placeholder={def.placeholder}
                        onChange={e => setParam(name, def, e.target.value)} />
                      <div style={{ fontSize: 11, color: colors.textTertiary, lineHeight: 1.5, marginTop: 2 }}>
                        {def.hint}
                      </div>
                    </div>
                  );
                })}
                <div style={{ fontSize: 11, color: colors.textTertiary, marginTop: 4 }}>
                  清空某项 = 该参数回落模型默认值。修改后自动保存。
                </div>
              </div>
            )}
          </div>
        );
      })}

      <div style={{ fontSize: 11, color: colors.textTertiary, marginTop: 2 }}>
        要为新模型配置参数，请在上方「模型列表」里点该模型的「参数」按钮。
      </div>

      {err && (
        <div style={{ ...calloutStyle('error'), marginTop: 8 }}>
          <Icon name="alert-circle" size={15} style={{ flexShrink: 0 }} />
          <span>{err}</span>
        </div>
      )}
    </div>
  );
}
