//
//  SSEEventKind.swift
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

//  SSE 事件类型枚举：全局基础设施，所有面板共用。
//  rawValue 与侧车事件名一一对应（契约对齐 subagent/renderer/src/panels/ChatPanel.tsx
//  的 applyEvent 白名单与 sidecar loop 的实际发出事件）：
//    token / thinking          增量事件（正文 / 思考）
//    tool_call / tool_result   工具调用与结果
//    state                     步骤状态（step/max）
//    done / error / cancelled  终态事件
//    segment_break             段落分隔（多段回复）
//    auth_request              授权请求（→ 全局授权中心 AuthCenter）
//    compact_required          上下文已满，需压缩
//    compact_auto              上下文已自动压缩（通知型）
//    message                   SSE 缺省类型（缺 event 行）
//
//  未知事件名不得让分发崩溃：SSEEvent.kind 返回 nil，面板按「忽略并记日志」处理。
//

import Foundation

public enum SSEEventKind: String, CaseIterable, Sendable {
    case token
    case thinking
    case toolCall = "tool_call"
    case toolResult = "tool_result"
    case state
    case done
    case error
    case cancelled
    case segmentBreak = "segment_break"
    case authRequest = "auth_request"
    case compactRequired = "compact_required"
    case compactAuto = "compact_auto"
    case message

    /// 增量事件（纪律①适用：必经 StreamAccumulator 缓冲 + 15fps 合帧 flush）
    public var isIncremental: Bool {
        self == .token || self == .thinking
    }

    /// 终态事件（流消费循环遇到即可收尾退出）
    public var isTerminal: Bool {
        self == .done || self == .error || self == .cancelled
    }
}

public extension SSEEvent {
    /// 类型化事件种类；未知事件名 → nil（调用方忽略，不要 crash）。
    var kind: SSEEventKind? { SSEEventKind(rawValue: event) }

    /// 是否为流终态（含 OpenAI 式 [DONE] 哨兵兼容）。
    var isTerminalEvent: Bool {
        (kind?.isTerminal ?? false) || isDoneSentinel
    }
}
