//
//  ModelOptionsEditorViewModel.swift
//  VetarAI — Local-first multi-agent orchestration application
//  Copyright (C) 2026 zero11924065-dev
//
//  This file is part of VetarAI.
//
//  VetarAI is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  VetarAI is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with VetarAI. If not, see <https://www.gnu.org/licenses/>.
//

//  每模型推理参数编辑器 ViewModel（逐段对标
//  subagent/renderer/src/panels/ModelOptionsEditor.tsx，324 行）：
//    · 参数表 PARAMS 与后端 sidecar/ollama/infer_options.py 的 _PARAM_MAP/_PARAM_RANGE
//      严格一致（后端是权威源，单边改动会被静默丢弃）
//    · REQ-INFER-009（0.4.28）草稿模式：onChange 只写本地草稿；blur/Enter 才 coerce
//      校验并提交；非法值提示且**草稿保留不回弹**；清空 = 回落模型默认
//    · 后端门禁：OpenAI 兼容端不支持 num_ctx/top_k（置灰）；0.4.31 起 num_ctx 对
//      模型包解锁（「上限」语义，懒加载档位表 ceiling）；repeat_penalty→frequency_penalty、
//      num_predict→max_tokens 的映射在后端做
//    · Enter 提交后紧接 blur 不重复 PUT（lastCommit 去重）；外部配置刷新重同步草稿，
//      聚焦中的字段除外
//

import Foundation
import Combine

/// 参数种类（对齐 TSX ParamDef.kind）。
public enum ModelOptionKind: String, Sendable {
    case int, float, list
}

/// 参数定义：键 = 后端规范名（Ollama 风格），与 infer_options._PARAM_MAP 一致。
public struct ModelOptionParamDef: Sendable {
    public let key: String
    public let label: String
    /// 该参数在 OpenAI 兼容后端是否不可用（对应 _PARAM_MAP['openai_compatible'] 的 None）
    public let ollamaOnly: Bool
    public let kind: ModelOptionKind
    public let min: Double?
    public let max: Double?
    public let hint: String
    public let placeholder: String

    public init(key: String, label: String, ollamaOnly: Bool = false, kind: ModelOptionKind,
                min: Double? = nil, max: Double? = nil, hint: String, placeholder: String) {
        self.key = key
        self.label = label
        self.ollamaOnly = ollamaOnly
        self.kind = kind
        self.min = min
        self.max = max
        self.hint = hint
        self.placeholder = placeholder
    }
}

/// 参数表：范围逐条对照后端 _PARAM_RANGE，勿单边修改（文案逐字对齐 TSX PARAMS）。
public enum ModelOptionParams {
    public static let all: [ModelOptionParamDef] = [
        ModelOptionParamDef(key: "num_ctx", label: "上下文上限 num_ctx", ollamaOnly: true, kind: .int,
                            min: 256, max: 1048576,
                            hint: "上限。懒加载开启时先以起始档（默认 12288）运行，上下文膨胀自动升档至此值；⚠️ 调大会显著拖慢首字（prefill），30B/35B 本地模型尤其明显；留空=用模型默认",
                            placeholder: "如 8192"),
        ModelOptionParamDef(key: "temperature", label: "随机性 temperature", kind: .float,
                            min: 0, max: 2,
                            hint: "越高越发散、越低越确定。留空=用模型默认", placeholder: "0.0 ~ 2.0"),
        ModelOptionParamDef(key: "top_p", label: "核采样 top_p", kind: .float,
                            min: 0, max: 1,
                            hint: "累积概率截断。留空=用模型默认", placeholder: "0.0 ~ 1.0"),
        ModelOptionParamDef(key: "top_k", label: "top_k", ollamaOnly: true, kind: .int,
                            min: 1, max: 1000,
                            hint: "每步只从概率最高的 K 个词里选。留空=用模型默认", placeholder: "如 40"),
        ModelOptionParamDef(key: "repeat_penalty", label: "重复惩罚 repeat_penalty", kind: .float,
                            min: 0, max: 3,
                            hint: ">1 抑制重复。OpenAI 兼容后端会映射为 frequency_penalty。留空=用模型默认",
                            placeholder: "如 1.1"),
        ModelOptionParamDef(key: "num_predict", label: "最大生成 num_predict", kind: .int,
                            min: -2, max: 1048576,
                            hint: "最多生成多少 token；-1=不限，-2=填满上下文。OpenAI 兼容后端映射为 max_tokens",
                            placeholder: "如 2048 或 -1"),
        ModelOptionParamDef(key: "seed", label: "随机种子 seed", kind: .int,
                            hint: "固定后可复现同样输出（用于排查\"每次结果不一样\"）。留空=随机",
                            placeholder: "如 42"),
        ModelOptionParamDef(key: "stop", label: "停止词 stop", kind: .list,
                            hint: "遇到这些字符串就停止生成，多个用英文逗号分隔。留空=不限制",
                            placeholder: "如 </s>, 用户:"),
    ]
}

/// coerce 结果（对齐 TSX coerce 的 ok/value 与 ok:false/why 两分支；空串 = 移除该项）。
public enum ModelOptionCoerce: Equatable, Sendable {
    case remove                 // 空 = 删除该项（回落模型默认）
    case int(Int)
    case double(Double)
    case list([String])
    case invalid(String)        // 原因文案（逐字对齐 TSX）
}

@MainActor
public final class ModelOptionsEditorViewModel: ObservableObject {

    // ── 视图状态 ──
    /// 本地草稿（REQ-INFER-009）：键 = fieldKey(model, paramKey)
    @Published public private(set) var drafts: [String: String] = [:]
    /// 展开的模型（单展开；缺省第一个已配置模型）
    @Published public var expandedModel: String?
    /// 校验错误提示（非法值提交时；草稿保留不回弹）
    @Published public private(set) var errorMessage: String?

    // ── 外部输入（父面板刷新时经 update(cfg:) 注入）──
    public private(set) var modelOptions: [String: [String: Any]] = [:]
    public var busy: Bool = false
    public var isOllama: Bool = true
    public var isModelPackage: Bool = false

    /// 保存回调 = 父面板 saveBackend(patch)（内部自捕错，不抛）；
    /// var + Bridge 名：父 VM 构建后才能回填（TSX 为 props.onSave）。
    public var onSaveBridge: ([String: Any]) async -> Void

    /// 正在聚焦编辑的字段：外部配置刷新时不同步它，避免打字到一半被覆盖
    private var focusKey: String?
    /// 上次成功提交的草稿原文：防 Enter 提交后紧接的 blur 对同一草稿重复 PUT
    private var lastCommit: [String: String] = [:]

    public init(onSave: @escaping ([String: Any]) async -> Void = { _ in }) {
        self.onSaveBridge = onSave
    }

    /// 草稿键：一模型一参数一格（对齐 TSX fieldKey）。
    public static func fieldKey(model: String, key: String) -> String {
        model + "\u{0}" + key
    }

    /// 已配置模型列表（稳定排序展示；JSON 对象无序，TSX 为插入序——近似按名字典序）。
    public var configuredModels: [String] {
        modelOptions.keys.sorted()
    }

    /// 该参数当前后端是否置灰（0.4.31：num_ctx 对模型包解锁）。
    public func isDisabled(_ def: ModelOptionParamDef) -> Bool {
        !isOllama && def.ollamaOnly && !(isModelPackage && def.key == "num_ctx")
    }

    /// 展示用受控值：草稿优先，未初始化回落已存值（对齐 TSX `drafts[k] ?? savedStr`）。
    public func displayValue(model: String, def: ModelOptionParamDef) -> String {
        let k = Self.fieldKey(model: model, key: def.key)
        return drafts[k] ?? Self.valueToString(def, modelOptions[model]?[def.key])
    }

    /// 已存值是否非空（对勾标记用）。
    public func hasSavedValue(model: String, def: ModelOptionParamDef) -> Bool {
        !Self.valueToString(def, modelOptions[model]?[def.key]).isEmpty
    }

    /// 已设参数计数（徽标「N 项已设 / 全部默认」）。
    public func configuredCount(model: String) -> Int {
        modelOptions[model]?.count ?? 0
    }

    // MARK: - 外部配置注入（保存成功 / Agent 改配置后的重拉）

    /// 草稿同步为已存值；聚焦中的字段除外（对齐 TSX useEffect [cfg]）。
    public func update(cfg: [String: Any], isOllama: Bool, isModelPackage: Bool, busy: Bool) {
        self.isOllama = isOllama
        self.isModelPackage = isModelPackage
        self.busy = busy
        let mo = (cfg["model_options"] as? [String: [String: Any]]) ?? [:]
        modelOptions = mo
        var next: [String: String] = [:]
        for name in mo.keys {
            for def in ModelOptionParams.all {
                let k = Self.fieldKey(model: name, key: def.key)
                if k == focusKey, let prev = drafts[k] {
                    next[k] = prev
                } else {
                    next[k] = Self.valueToString(def, mo[name]?[def.key])
                }
            }
        }
        drafts = next
        // 缺省展开第一个已配置模型（对齐 TSX useState(configured[0] ?? null)），
        // 若当前展开项已被移除则回落
        if let cur = expandedModel, mo[cur] != nil { /* 保持 */ } else {
            expandedModel = configuredModels.first
        }
    }

    /// 父级点了某个模型的「参数」按钮 → 展开它（受控；对齐 useEffect [focus]）。
    public func focus(model: String) {
        if modelOptions[model] != nil { expandedModel = model }
    }

    /// 输入事件：只写草稿（REQ-INFER-009 草稿模式核心）。
    public func editDraft(model: String, def: ModelOptionParamDef, text: String) {
        drafts[Self.fieldKey(model: model, key: def.key)] = text
    }

    public func beginFocus(model: String, def: ModelOptionParamDef) {
        focusKey = Self.fieldKey(model: model, key: def.key)
    }

    /// blur：清聚焦标记并提交（对齐 onBlur）。
    public func endFocus(model: String, def: ModelOptionParamDef) {
        focusKey = nil
        commit(model: model, def: def)
    }

    // MARK: - 校验（逐字对齐 TSX coerce）

    /// 校验单个值；合法返回收窄后的值，非法返回 invalid（含原因文案）。
    nonisolated public static func coerce(_ def: ModelOptionParamDef, raw: String) -> ModelOptionCoerce {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return .remove }
        if def.kind == .list {
            let arr = t.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return arr.isEmpty ? .remove : .list(arr)
        }
        guard let n = Double(t) else {
            return .invalid("\(def.label) 必须是数字")
        }
        if def.kind == .int && n != n.rounded() {
            return .invalid("\(def.label) 必须是整数")
        }
        if let min = def.min, n < min {
            return .invalid("\(def.label) 不得小于 \(formatBound(min))")
        }
        if let max = def.max, n > max {
            return .invalid("\(def.label) 不得大于 \(formatBound(max))")
        }
        return def.kind == .int ? .int(Int(n)) : .double(n)
    }

    /// 边界值格式化（TSX 模板字符串直接插数值：256 / 1048576 / 0.5 不带多余小数）。
    nonisolated static func formatBound(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(v)
    }

    /// 已存值 → 草稿串（对齐 TSX valueToString：list 逗号+空格连接；null/缺省 = ""）。
    nonisolated public static func valueToString(_ def: ModelOptionParamDef, _ value: Any?) -> String {
        guard let value else { return "" }
        if value is NSNull { return "" }
        if def.kind == .list {
            if let arr = value as? [String] { return arr.joined(separator: ", ") }
            if let arr = value as? [Any] { return arr.map { "\($0)" }.joined(separator: ", ") }
            return "\(value)"
        }
        if let n = value as? NSNumber {
            // 整数值不带 .0（对齐 JS String(v)：String(2.0)==="2"）
            let d = n.doubleValue
            if d == d.rounded() && abs(d) < 1e15 { return String(Int64(d)) }
            return String(d)
        }
        return "\(value)"
    }

    // MARK: - 提交（blur / Enter 唯一保存入口）

    /// 提交当前草稿：未改动 / Enter 后紧接 blur 不重复 PUT；非法值提示且草稿保留。
    public func commit(model: String, def: ModelOptionParamDef) {
        let k = Self.fieldKey(model: model, key: def.key)
        let raw = drafts[k] ?? Self.valueToString(def, modelOptions[model]?[def.key])
        let savedStr = Self.valueToString(def, modelOptions[model]?[def.key])
        if raw == savedStr { return }                 // 未改动：不校验不保存
        if lastCommit[k] == raw { return }            // Enter 后紧接 blur：不重复提交
        switch Self.coerce(def, raw: raw) {
        case .invalid(let why):
            errorMessage = why                        // ⛔ 草稿保留，不回弹（REQ-INFER-009）
            return
        case .remove:
            applyCommit(model: model, def: def, k: k, raw: raw, value: nil)
        case .int(let n):
            applyCommit(model: model, def: def, k: k, raw: raw, value: n)
        case .double(let d):
            applyCommit(model: model, def: def, k: k, raw: raw, value: d)
        case .list(let arr):
            applyCommit(model: model, def: def, k: k, raw: raw, value: arr)
        }
    }

    private func applyCommit(model: String, def: ModelOptionParamDef, k: String, raw: String, value: Any?) {
        errorMessage = nil
        var mo = modelOptions
        var cur = mo[model] ?? [:]
        if let value {
            cur[def.key] = value
        } else {
            cur.removeValue(forKey: def.key)          // 空值 = 移除该项，回落模型默认
        }
        mo[model] = cur
        lastCommit[k] = raw
        // 保存成功 → 草稿同步为归一化后的已存值（" 256 " → "256"）
        drafts[k] = value.map { Self.valueToString(def, $0) } ?? ""
        let captured = mo
        Task { await onSaveBridge(["model_options": captured]) }
    }

    /// 移除某模型的全部参数配置（行尾垃圾桶；对齐 removeModel）。
    public func removeModel(_ name: String) {
        var mo = modelOptions
        mo.removeValue(forKey: name)
        errorMessage = nil
        if expandedModel == name { expandedModel = mo.keys.sorted().first }
        let captured = mo
        Task { await onSaveBridge(["model_options": captured]) }
    }
}
