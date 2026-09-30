//
//  NativeAppEvents+ModelCatalog.swift
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

//  背景：.vmodel 安装/移除/启停（NativeVModelInstaller 三写路径）与模型包
// （GGUF/MLX）生命周期都会改变「聊天/Agent 模型选择列表」的并集数据源
// （NativeKernel.mpVModelUnion + modelsMP 退化面均为注册表实时直读）。
// 0.7.15 前三个消费 VM（Chat/AgentPanel/IndependentAgentsPanel）只在
// bootstrap/init 拉一次 listModels，不订阅总线——新装模型要重启 App 才可选。
//
//  发布侧：installer 三写路径成功即 notify(vmodel, create/update/delete)
// （旁路不抛异常纪律内建）；模型包走 NativeModelPackEndpoints 既有 notify。
//  订阅侧：ChatViewModel / AgentPanelViewModel / IndependentAgentsPanelViewModel
// （本文件提供过滤助手）。
//
//  ⛔ 本文件为扩展，不改动 NativeAppEvents.swift 本体（核心域只读纪律）。
//

import Foundation

extension NativeAppEvents {

    /// 订阅侧过滤：本事件是否为「模型目录变更」（resource_changed &&
    /// resource ∈ {vmodel, model_pack}）——模型选择列表应重拉 listModels。
    /// action 不限定：create/delete/update/下载完成等任何写动作都可能改并集。
    public static func isModelCatalogChangedEvent(_ ev: NativeAppBusEvent) -> Bool {
        guard ev.event == "resource_changed",
              let res = ev.data["resource"]?.string else { return false }
        return res == resourceVModel || res == resourceModelPack
    }
}
