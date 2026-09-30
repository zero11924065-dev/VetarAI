//
//  SidecarClient+IndependentAgents.swift
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

//  独立 Agent 面板扩展端点（checkpoint-058：与项目平级的一等公民，ia- 命名空间隔离）。
//  沿用子协议分层：IndependentAgentsPanelClient，生产实现 = NativeSidecarClient。
//  HTTP 扩展实现已于 P3-W6 随侧车归零退役删除。
//
//  端点契约逐条对照 subagent/sidecar/app.py + storage/store.py（行号为移植时核对位置）：
//    GET    /api/independent-agents           app.py L346 → store.list_independent_agents
//           [{id, name, role, system_prompt, model_name, created_at}]（ORDER BY created_at 升序）
//    POST   /api/independent-agents           app.py L336 {name, model_name?, system_prompt?}
//           → {agent_id}；422 detail=名称不能为空
//    PUT    /api/independent-agents/{aid}     app.py L350 {name?, system_prompt?, model_name?}
//           → {updated:true}；404 detail=独立 Agent 不存在或无有效更新字段
//           ⚠️ 空串是有效值（system_prompt:"" = 清除角色设定）；nil 键必须省略
//    DELETE /api/independent-agents/{aid}     app.py L359 → {deleted:true}；404 detail=独立 Agent 不存在
//

import Foundation

// MARK: - 契约模型

/// 独立 Agent（GET /api/independent-agents 行；宽容解码，除 id/name 外均可缺）。
public struct IndependentAgent: Decodable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let role: String?
    public let system_prompt: String?
    public let model_name: String?
    public let created_at: String?

    public init(id: String, name: String, role: String? = nil,
                system_prompt: String? = nil, model_name: String? = nil,
                created_at: String? = nil) {
        self.id = id
        self.name = name
        self.role = role
        self.system_prompt = system_prompt
        self.model_name = model_name
        self.created_at = created_at
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let id = try c.decodeIfPresent(String.self, forKey: .id) else {
            throw DecodingError.keyNotFound(CodingKeys.id, .init(
                codingPath: decoder.codingPath, debugDescription: "IndependentAgent.id 缺失"))
        }
        self.id = id
        self.name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        self.role = try c.decodeIfPresent(String.self, forKey: .role)
        self.system_prompt = try c.decodeIfPresent(String.self, forKey: .system_prompt)
        self.model_name = try c.decodeIfPresent(String.self, forKey: .model_name)
        self.created_at = try c.decodeIfPresent(String.self, forKey: .created_at)
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, role, system_prompt, model_name, created_at
    }
}

/// POST /api/independent-agents 请求体（nil 键省略 = 后端 None = 存 NULL）。
public struct IndependentAgentCreateRequest: Encodable {
    public let name: String
    public let model_name: String?
    public let system_prompt: String?

    public init(name: String, model_name: String? = nil, system_prompt: String? = nil) {
        self.name = name
        self.model_name = model_name
        self.system_prompt = system_prompt
    }
}

/// PUT /api/independent-agents/{aid} 请求体（nil 键省略；空串照常编码 = 清除语义）。
public struct IndependentAgentUpdateRequest: Encodable {
    public let name: String?
    public let system_prompt: String?
    public let model_name: String?

    public init(name: String? = nil, system_prompt: String? = nil, model_name: String? = nil) {
        self.name = name
        self.system_prompt = system_prompt
        self.model_name = model_name
    }
}

// MARK: - 子协议

public protocol IndependentAgentsPanelClient: SidecarClientProtocol {
    /// GET /api/independent-agents：独立 Agent 列表（失败由面板静默，对齐现状 catch{}）。
    func listIndependentAgents() async throws -> [IndependentAgent]

    /// POST /api/independent-agents：创建（名称面板已兜底非空），返回 agent_id。
    @discardableResult
    func createIndependentAgent(name: String, modelName: String?, systemPrompt: String?) async throws -> String

    /// PUT /api/independent-agents/{aid}：改名称/角色设定/模型（只传要改的键）。
    func updateIndependentAgent(agentId: String, update: IndependentAgentUpdateRequest) async throws

    /// DELETE /api/independent-agents/{aid}：删除（注册记录 + ia-<id> 命名空间数据目录全清）。
    func deleteIndependentAgent(agentId: String) async throws
}
