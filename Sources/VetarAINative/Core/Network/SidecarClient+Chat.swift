//
//  SidecarClient+Chat.swift
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

//  会话面板扩展端点。为不改动 Wave 0 的 SidecarClientProtocol 声明
//  （并行波次共享该文件），新增端点收在子协议 ChatPanelClient 里：
//  生产实现 = NativeSidecarClient；面板测试用自己的 mock 实现本协议。
//  HTTP 扩展实现已于 P3-W6 随侧车归零退役删除。
//
//  端点契约逐条对照 subagent/sidecar/app.py（行号为移植时核对位置）：
//    GET    /api/config                                   探活 + 读配置项
//    GET    /api/context/limit?model=                     上下文上限（0.4.34 懒加载口径）
//    PUT    /api/sessions/{sid}?project_id=               重命名会话 {title}
//    DELETE /api/sessions/{sid}?project_id=               删除会话
//    POST   /api/sessions/{sid}/compact?project_id=       智能压缩 {}
//    POST   /api/sessions/{sid}/export                    导出 Markdown {project_id, agent_id, dir?}
//    POST   /api/sessions/{sid}/summarize                 自动总结 {project_id, agent_id, model}
//    POST   /api/attachments/parse                        附件解析+落盘 {name, content_base64, project_id, session_id}
//    POST   /api/chat/{sid}/inject                        思考中插入消息 {project_id, agent_id, content}
//    PUT    /api/agents/{pid}/{aid}                       更新 Agent（模型降级卡片用）{model_name}
//    POST   /api/ollama/pull                              拉取模型 {name}
//    GET    /api/inference/status                         推理后端（视觉引导卡 ollama 判定）
//    POST   /api/knowledge/transfer                       消息移入知识仓库（TS-120）
//

import Foundation

public protocol ChatPanelClient: SidecarClientProtocol {
    func fetchConfig() async throws -> [String: Any]
    func fetchContextLimit(model: String) async throws -> ContextLimitInfo
    func renameSession(projectId: String, sessionId: String, title: String) async throws
    @discardableResult
    func deleteSession(projectId: String, sessionId: String) async throws -> Bool
    func compactSession(projectId: String, sessionId: String) async throws
    func exportSession(projectId: String, agentId: String, sessionId: String, dir: String?) async throws -> ExportResult
    func summarizeSession(projectId: String, agentId: String, sessionId: String, model: String) async throws -> SummarizeResult
    func parseAttachment(name: String, contentBase64: String,
                         projectId: String, sessionId: String) async throws -> AttachmentParseResult
    func injectMessage(projectId: String, agentId: String,
                       sessionId: String, content: String) async throws -> InjectResult
    func updateAgentModel(projectId: String, agentId: String, modelName: String) async throws
    func pullModel(name: String) async throws
    /// 返回 inference_backend（"ollama" / "openai_compatible" / "model_package"…）。
    func fetchInferenceBackend() async throws -> String
    func transferToWarehouse(_ req: KnowledgeTransferRequest) async throws -> KnowledgeTransferResult
}
