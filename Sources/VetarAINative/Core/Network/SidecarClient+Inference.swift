//
//  SidecarClient+Inference.swift
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

//  推理面板（InferencePanel）+ 模型选项编辑器（ModelOptionsEditor）+ 模型包面板
//  （ModelPacksPanel）扩展端点。沿用 Wave 1 的子协议模式，不改 Wave 0 协议文件：
//  生产实现 = NativeSidecarClient；面板测试注入自己的 mock。
//  HTTP 扩展实现已于 P3-W6 随侧车归零退役删除。
//
//  端点契约逐条对照 subagent/sidecar/app.py：
//    GET    /api/config                            读全量配置（fetchConfig，Chat 扩展已有实现）
//    PUT    /api/config                            补丁写回（后端 reload_config 合并语义，
//                                                  未知键 400；app.py:264 + config/store.py:491）
//    GET    /api/inference/status                  推理后端状态（app.py:446）
//    GET    /api/inference/models                  统一模型列表（app.py:474）
//    POST   /api/ollama/pull                       拉取模型 {name}（Chat 扩展已有实现）
//    DELETE /api/ollama/models/{name}              删除模型（app.py:437）
//    GET    /api/model-packs                       已安装模型包（app.py:2781）
//    GET    /api/model-packs/catalog               目录合并（app.py:2787）
//    POST   /api/model-packs/install               安装 {pack_id, catalog_entry}（app.py:2822）
//    POST   /api/model-packs/cancel                取消下载 {pack_id}（app.py:2856）
//    DELETE /api/model-packs/{pack_id}             卸载（app.py:2867）
//    POST   /api/model-packs/{pack_id}/toggle      启用/禁用 {enabled}（app.py:2886）
//    GET    /api/events/stream?since=              全局资源变更 SSE（app.py:1716，
//                                                  resource_changed / gap / stream_end）
//

import Foundation

// MARK: - 推理面板客户端协议

public protocol InferencePanelClient: SidecarClientProtocol {
    /// GET /api/config 全量配置（未知键原文保留，供面板读各键）。
    func fetchConfig() async throws -> [String: Any]
    /// PUT /api/config 补丁写回（后端 reload_config 为**合并**语义：patch 逐键覆盖，
    /// 未知键 400；对齐 SettingsPanel 扩展的 updateConfig 口径，比 TSX 的
    /// {...cfg, ...patch} 全量回写更不容易误伤并行面板的并发改动）。
    func putConfig(_ patch: [String: Any]) async throws
    /// GET /api/inference/status
    func fetchInferenceStatus() async throws -> InferenceStatusInfo
    /// GET /api/inference/models（后端不可达时后端 502；面板按现状容错为空列表）
    func fetchInferenceModels() async throws -> [InferenceModelEntry]
    /// POST /api/ollama/pull（与 ChatPanelClient 共用同一方法）
    func pullModel(name: String) async throws
    /// DELETE /api/ollama/models/{name}
    func deleteModel(name: String) async throws
    /// GET /api/events/stream?since= 全局资源变更流（断连重连带 since 补发）。
    func appEventsStream(since: Int) -> AsyncThrowingStream<SSEEvent, Error>
}

// MARK: - 模型包面板客户端协议

public protocol ModelPacksPanelClient: SidecarClientProtocol {
    func fetchConfig() async throws -> [String: Any]
    /// PUT /api/config 补丁写回（合并语义，见 InferencePanelClient.putConfig 注）。
    func putConfig(_ patch: [String: Any]) async throws
    /// GET /api/model-packs
    func listModelPacks() async throws -> ModelPackListResponse
    /// GET /api/model-packs/catalog；rawEntries = 每个 pack 的原始 JSON 字典
    /// （安装时 catalog_entry 原样回传，保住 context_length/sample_rate 等可选键）。
    func fetchModelPackCatalog() async throws -> (catalog: ModelPackCatalogResponse,
                                                  rawEntries: [String: [String: Any]])
    /// POST /api/model-packs/install {pack_id, catalog_entry}（立即返回，进度走 SSE）。
    func installModelPack(packId: String, catalogEntry: [String: Any]) async throws
    /// POST /api/model-packs/cancel {pack_id}
    func cancelModelPackDownload(packId: String) async throws
    /// DELETE /api/model-packs/{pack_id}
    func deleteModelPack(packId: String) async throws
    /// POST /api/model-packs/{pack_id}/toggle {enabled}
    func toggleModelPack(packId: String, enabled: Bool) async throws
    func appEventsStream(since: Int) -> AsyncThrowingStream<SSEEvent, Error>
}
