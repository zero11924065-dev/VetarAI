//
//  NativeAppEvents+Agent.swift
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

//  背景：IndependentAgentsPanelViewModel / AgentPanelViewModel 行内编辑
// （模型切换 / 角色设定保存）后，壳应用 emit('agent:updated') 通知 ChatPanel
//  刷新 agentInfo；原生侧曾记两处「事件总线未建」待办，暂经 AppState 观察过渡。
//
//  核销事实链（0.7.4 逐行核实）：
//    · A13 资源总线已于 P2-W4d1 交付（NativeAppEvents，resource/update 语义现成）；
//    · 发布侧已在端点层接线（app.py 逐行为口径）——
//      NativeSidecarClient.updateAgent（app.py L812）与
//      NativeSidecarClient+Panels.updateIndependentAgent（app.py L356）
//      成功即广播 agent/update（data 带 agent_id）；
//      ⛔ 面板 ViewModel 不得重复发布（双发违背端点单发语义）；
//    · 订阅侧 = ChatViewModel（本文件提供过滤助手）。
//
//  ⛔ 本文件为扩展，不改动 NativeAppEvents.swift 本体（核心域只读纪律）。
//

import Foundation

extension NativeAppEvents {

    /// 订阅侧过滤：本事件是否为「Agent 更新」（resource_changed && resource=agent
    /// && action=update）。壳应用前端 'agent:updated' 的原生等价判定；
    /// 载荷约定：data["agent_id"] = 被更新 Agent id（端点层发布口径）。
    public static func isAgentUpdatedEvent(_ ev: NativeAppBusEvent) -> Bool {
        ev.event == "resource_changed"
            && ev.data["resource"]?.string == resourceAgent
            && ev.data["action"]?.string == actionUpdate
    }
}
