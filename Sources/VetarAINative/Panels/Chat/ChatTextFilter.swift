//
//  ChatTextFilter.swift
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

//  空 think 块渲染滤除。出处：VetarModel 联调回执（2026-09-27）建议 1——
//  vmodel 回答气泡原文显示空 <think></think> 标签（Qwen 系底座正常产物），
//  渲染层在 Markdown 渲染前加一道文本过滤。命名对齐 VetarModel 侧同语义
//  实现 ChatTextFilter（Sources/VetarModel/Chat/ChatTextFilter.swift）。
//
//  口径差异（如实登记，勿互相移植语义）：
//    · VetarModel 侧 = 黑盒守护：剥全部闭合 think 块（用户不看思考过程），
//      流式中途另把未闭合尾部临时藏掉。
//    · 本侧（VetarAI）= 有思考块 UI（thinking 通道 preview/duration），
//      回执口径逐字：「剔除空的或纯空白内容的 <think>...</think> 块，
//      非空思考块按现有思考块 UI 正常展示」——即只剥空块，非空块原样保留。
//
//  流式安全（回执纪律：不要把流式中间态的非空内容误杀）：
//    只处理「完整闭合」的块——<think> 已开未合的尾部原样保留（它可能还在
//    接收思考内容，此时判定为空为时过早）；块闭合瞬间内容即定型，闭合空块
//    剔除不可能误杀后续内容。本函数在渲染层对全量文本反复调用（15fps 合帧
//    后的气泡重渲染），幂等，无副作用。
//
//  已知边界（与 VetarModel 侧同款，刻意保持简单）：代码围栏内字面书写的
//  <think></think> 示例同样会被剔除——模型输出里演示 think 标签的场景
//  极罕见，且对端同口径，不做围栏感知。
//

import Foundation

public enum ChatTextFilter {

    /// 剔除空的或纯空白内容的 <think>...</think> 完整闭合块（可多处）；
    /// 非空闭合块与未闭合尾部原样保留。仅当确有剔除时，结果做首尾空白裁剪
    /// （空块摘除后遗留的空行收口；与 VetarModel ChatTextFilter 同款收尾口径）。
    /// 未剔除任何块时逐字返回原文（不动有意的首尾空白）。
    public static func stripEmptyThinkBlocks(_ text: String) -> String {
        guard text.contains("<think>") else { return text }
        var out = ""
        var cursor = text.startIndex
        var strippedAny = false
        while let openRange = text.range(of: "<think>", range: cursor..<text.endIndex) {
            guard let closeRange = text.range(
                of: "</think>", range: openRange.upperBound..<text.endIndex) else {
                break   // 未闭合（流式中间态 / 正文提及标签）→ 余下原样保留
            }
            let inner = text[openRange.upperBound..<closeRange.lowerBound]
            if inner.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // 空块：块前文本落盘，块整体（标签+空白内容）剔除
                out += text[cursor..<openRange.lowerBound]
                strippedAny = true
            } else {
                // 非空思考块：原样保留（现有思考块 UI 口径，不动展示语义）
                out += text[cursor..<closeRange.upperBound]
            }
            cursor = closeRange.upperBound
        }
        guard strippedAny else { return text }
        out += text[cursor...]
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
