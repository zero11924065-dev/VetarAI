//
//  SidecarClient+Knowledge.swift
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

//  知识记忆面板（KnowledgePanel，四标签）+ 知识仓库检索面板（WarehousePanel）
//  + 知识仓库资产管理器（WarehouseManager）扩展端点。
//  沿用 Wave 2 的子协议模式，不改 Wave 0 协议文件：
//  生产实现 = NativeSidecarClient；面板测试注入自己的 mock。
//  HTTP 扩展实现已于 P3-W6 随侧车归零退役删除。
//
//  端点契约逐条对照 subagent/sidecar/app.py 与 knowledge/warehouse.py、
//  knowledge/store_knowledge.py、skills_mgr/manager.py：
//    ── KnowledgeTab（推模式知识库，项目 knowledge/ 目录 .md，自动注入 Agent）──
//    GET    /api/projects/{pid}/knowledge                 [{name,size,enabled}]（app.py:2054）
//    GET    /api/projects/{pid}/knowledge/{name}          {name,content}；404 非法/不存在（2058）
//    PUT    /api/projects/{pid}/knowledge                 {name,content}→{ok,name}；非 .md 400（2069）
//    DELETE /api/projects/{pid}/knowledge/{name}          {ok}；404（2079）
//    POST   /api/projects/{pid}/knowledge/{name}/toggle   {ok,name=新名}（_ 前缀切换）；400（2086）
//    ── MemoryTab（全局/项目两份记忆）──
//    GET    /api/memory?scope=&project_id=                {scope,content}；scope 非法 400（2094）
//    PUT    /api/memory                                   {scope,project_id,content}→{ok}（2105）
//    ── SkillsTab（SKILL.md 技能）──
//    GET    /api/skills                                   [{name,dir_name,description,enabled,path}]（2114）
//    POST   /api/skills                                   {name,description,body,enabled}→{ok,name}；非法名 400（2124）
//    PUT    /api/skills/{name}                            同体→{ok,name}（2130）
//    GET    /api/skills/{name}                            {name,dir_name,description,enabled,content}；404（2136）
//    DELETE /api/skills/{name}                            {ok}；404（2143）
//    POST   /api/skills/{name}/toggle                     {ok,enabled}；400（2149）
//    POST   /api/skills/install                           {url}→{ok,name?}；失败 400 detail（2159）
//    ── WarehousePanel / WarehouseManager（拉模式知识仓库，永不自动注入上下文）──
//    GET    /api/knowledge/entries?scope=&project_id=     [{id,title,scope,project_id,category,
//                                                         keywords,source,file_path,created_at}]（2556）
//    GET    /api/knowledge/search?q=&scope=&project_id=&limit=&mode=
//                                                         同上 + hybrid/semantic 带 score（2563）
//    GET    /api/knowledge/embedding-status               {available,model,model_dir,
//                                                         entries_total,entries_embedded}（2575）
//    POST   /api/knowledge/inject                         {entry_ids}→{ok,text}；无有效条目 404（2595）
//    POST   /api/knowledge/rebuild-index                  {ok,entries}（2609）
//    GET    /api/knowledge/groups                         [{scope,project_id,project_name,count,dir}]（2623）
//    POST   /api/knowledge/open-dir                       {scope,project_id}→{ok,dir}；
//                                                         200 但 {ok:false,detail}（非 macOS/超时）（2651）
//    POST   /api/knowledge/import-files                   {scope,project_id,paths,on_conflict}→
//           {imported,failed,skipped,conflicts:[name],details:[{name,status,reason?}]}（2682）
//

import Foundation

// MARK: - 契约模型（Codable；后端字段缺失宽容）

/// 推模式知识库条目（项目 knowledge/ 目录 .md；_ 前缀 = 禁用不注入）。
public struct KnowledgeFileItem: Codable, Equatable, Sendable {
    public var name: String
    public var size: Int
    public var enabled: Bool
    public init(name: String, size: Int = 0, enabled: Bool = true) {
        self.name = name
        self.size = size
        self.enabled = enabled
    }
}

/// 知识文件正文（GET /knowledge/{name}）。
public struct KnowledgeFileContent: Codable, Equatable, Sendable {
    public var name: String
    public var content: String
    public init(name: String, content: String = "") {
        self.name = name
        self.content = content
    }
}

/// 记忆读取响应（GET /memory）。
public struct MemoryContent: Codable, Equatable, Sendable {
    public var scope: String
    public var content: String
    public init(scope: String, content: String = "") {
        self.scope = scope
        self.content = content
    }
}

/// 技能列表条目（GET /skills）。
public struct SkillItem: Codable, Equatable, Sendable {
    public var name: String
    public var dir_name: String
    public var description: String
    public var enabled: Bool
    public var path: String?
    public init(name: String, dir_name: String, description: String = "",
                enabled: Bool = true, path: String? = nil) {
        self.name = name
        self.dir_name = dir_name
        self.description = description
        self.enabled = enabled
        self.path = path
    }
}

/// 技能详情（GET /skills/{name}，含正文 content）。
public struct SkillDetail: Codable, Equatable, Sendable {
    public var name: String
    public var dir_name: String
    public var description: String
    public var enabled: Bool
    public var content: String
    public init(name: String, dir_name: String, description: String = "",
                enabled: Bool = true, content: String = "") {
        self.name = name
        self.dir_name = dir_name
        self.description = description
        self.enabled = enabled
        self.content = content
    }
}

/// 拉模式知识仓库条目（/knowledge/entries 与 /knowledge/search 共用；
/// 列表无 body/score，hybrid/semantic 检索带 score）。
public struct WarehouseEntry: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var scope: String
    public var project_id: String?
    public var category: String?
    public var keywords: [String]?
    public var source: String?
    public var file_path: String?
    public var created_at: String?
    public var body: String?
    /// 阶段二：混合/语义检索返回的相关度得分（keyword 模式无）。
    public var score: Double?

    public init(id: String, title: String, scope: String, project_id: String? = nil,
                category: String? = nil, keywords: [String]? = nil, source: String? = nil,
                file_path: String? = nil, created_at: String? = nil,
                body: String? = nil, score: Double? = nil) {
        self.id = id
        self.title = title
        self.scope = scope
        self.project_id = project_id
        self.category = category
        self.keywords = keywords
        self.source = source
        self.file_path = file_path
        self.created_at = created_at
        self.body = body
        self.score = score
    }

    /// 自定义解码：后端 scope 一定存在，其余字段宽容（对齐 TSX 全可选口径）。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? ""
        title = (try? c.decode(String.self, forKey: .title)) ?? ""
        scope = (try? c.decode(String.self, forKey: .scope)) ?? "global"
        project_id = try? c.decode(String.self, forKey: .project_id)
        category = try? c.decode(String.self, forKey: .category)
        keywords = try? c.decode([String].self, forKey: .keywords)
        source = try? c.decode(String.self, forKey: .source)
        file_path = try? c.decode(String.self, forKey: .file_path)
        created_at = try? c.decode(String.self, forKey: .created_at)
        body = try? c.decode(String.self, forKey: .body)
        // score 可能是 Int/Double 混合（JSON 数字），宽容转换
        if let d = try? c.decode(Double.self, forKey: .score) {
            score = d
        } else if let i = try? c.decode(Int.self, forKey: .score) {
            score = Double(i)
        } else {
            score = nil
        }
    }
}

/// 嵌入模型状态（GET /knowledge/embedding-status）。
public struct EmbeddingStatus: Codable, Equatable, Sendable {
    public var available: Bool
    public var model: String?
    public var model_dir: String?
    public var entries_total: Int
    public var entries_embedded: Int
    /// 0.5.2 A1：装载三态（notLoaded/loading/loaded/failed；nil = 旧侧车无此字段）。
    public var load_state: String?
    public init(available: Bool, model: String? = nil, model_dir: String? = nil,
                entries_total: Int = 0, entries_embedded: Int = 0,
                load_state: String? = nil) {
        self.available = available
        self.model = model
        self.model_dir = model_dir
        self.entries_total = entries_total
        self.entries_embedded = entries_embedded
        self.load_state = load_state
    }
}

/// 知识分组（GET /knowledge/groups）：全局组 + 各项目组。
public struct KnowledgeGroup: Codable, Equatable, Sendable, Identifiable {
    public var scope: String
    public var project_id: String?
    public var project_name: String
    public var count: Int
    public var dir: String

    public var id: String { scope + (project_id ?? "") }

    public init(scope: String, project_id: String? = nil, project_name: String,
                count: Int = 0, dir: String = "") {
        self.scope = scope
        self.project_id = project_id
        self.project_name = project_name
        self.count = count
        self.dir = dir
    }
}

/// POST /knowledge/inject 响应。
public struct KnowledgeInjectResponse: Codable, Equatable, Sendable {
    public var ok: Bool
    public var text: String
    public init(ok: Bool, text: String) {
        self.ok = ok
        self.text = text
    }
}

/// POST /knowledge/rebuild-index 响应。
public struct KnowledgeRebuildResult: Codable, Equatable, Sendable {
    public var ok: Bool
    public var entries: Int
    public init(ok: Bool, entries: Int = 0) {
        self.ok = ok
        self.entries = entries
    }
}

/// POST /knowledge/open-dir 响应：注意 200 也可能 {ok:false, detail}（非 macOS/超时）。
public struct KnowledgeOpenDirResult: Codable, Equatable, Sendable {
    public var ok: Bool
    public var dir: String?
    public var detail: String?
    public init(ok: Bool, dir: String? = nil, detail: String? = nil) {
        self.ok = ok
        self.dir = dir
        self.detail = detail
    }
}

/// import-files 逐文件明细。
public struct KnowledgeImportDetail: Codable, Equatable, Sendable {
    public var name: String
    public var status: String
    public var reason: String?
    public var conflict_resolved: String?
    public init(name: String, status: String, reason: String? = nil,
                conflict_resolved: String? = nil) {
        self.name = name
        self.status = status
        self.reason = reason
        self.conflict_resolved = conflict_resolved
    }
}

/// POST /knowledge/import-files 响应（两趟 ask→策略 的结果在前端 VM 合并）。
public struct KnowledgeImportResult: Codable, Equatable, Sendable {
    public var imported: Int
    public var failed: Int
    public var skipped: Int
    public var conflicts: [String]
    public var details: [KnowledgeImportDetail]
    public init(imported: Int = 0, failed: Int = 0, skipped: Int = 0,
                conflicts: [String] = [], details: [KnowledgeImportDetail] = []) {
        self.imported = imported
        self.failed = failed
        self.skipped = skipped
        self.conflicts = conflicts
        self.details = details
    }
}

// MARK: - KnowledgePanel 客户端协议（知识库 / 记忆 / 技能三标签共用；
//          「知识仓库」标签复用 WarehouseManagerClient）

public protocol KnowledgePanelClient: SidecarClientProtocol {
    /// GET /api/projects/{pid}/knowledge
    func listKnowledge(projectId: String) async throws -> [KnowledgeFileItem]
    /// GET /api/projects/{pid}/knowledge/{name}（404 → httpError）
    func readKnowledge(projectId: String, name: String) async throws -> KnowledgeFileContent
    /// PUT /api/projects/{pid}/knowledge {name, content}（新建与保存同端点）
    func writeKnowledge(projectId: String, name: String, content: String) async throws
    /// DELETE /api/projects/{pid}/knowledge/{name}
    func deleteKnowledge(projectId: String, name: String) async throws
    /// POST …/toggle → 新文件名（_ 前缀切换）
    @discardableResult
    func toggleKnowledge(projectId: String, name: String) async throws -> String

    /// GET /api/memory?scope=&project_id=
    func readMemory(scope: String, projectId: String?) async throws -> MemoryContent
    /// PUT /api/memory {scope, project_id, content}
    func writeMemory(scope: String, projectId: String?, content: String) async throws

    /// GET /api/skills
    func listSkills() async throws -> [SkillItem]
    /// GET /api/skills/{dirName}
    func readSkill(dirName: String) async throws -> SkillDetail
    /// POST /api/skills（新建）
    func createSkill(name: String, description: String, body: String, enabled: Bool) async throws
    /// PUT /api/skills/{dirName}（更新；name 不可改——TSX 编辑态禁用名输入框）
    func updateSkill(dirName: String, description: String, body: String, enabled: Bool) async throws
    /// DELETE /api/skills/{dirName}
    func deleteSkill(dirName: String) async throws
    /// POST /api/skills/{dirName}/toggle → 新启用状态
    @discardableResult
    func toggleSkill(dirName: String) async throws -> Bool
    /// POST /api/skills/install {url}（仓库地址或本地路径，含 SKILL.md）
    func installSkill(url: String) async throws

    /// GET /api/events/stream?since= 全局资源变更流（A13：Agent 改知识库后实时重拉）。
    /// 与 Wave 2 两面板共用同一方法（NativeSidecarClient 单实现满足）。
    func appEventsStream(since: Int) -> AsyncThrowingStream<SSEEvent, Error>
}

// MARK: - WarehousePanel 客户端协议（会话右侧检索/注入面板）

public protocol WarehousePanelClient: SidecarClientProtocol {
    /// GET /api/knowledge/entries?scope=&project_id=
    func listWarehouseEntries(scope: String, projectId: String?) async throws -> [WarehouseEntry]
    /// GET /api/knowledge/search?q=&mode=&scope=&project_id=（mode ∈ hybrid/keyword/semantic）
    func searchWarehouse(query: String, scope: String, projectId: String?,
                         mode: String, limit: Int) async throws -> [WarehouseEntry]
    /// POST /api/knowledge/inject {entry_ids} → 拼接好的注入文本
    func injectWarehouseEntries(entryIds: [String]) async throws -> String
}

// MARK: - WarehouseManager 客户端协议（设置页「知识仓库」资产管理器）

public protocol WarehouseManagerClient: SidecarClientProtocol {
    /// GET /api/knowledge/groups
    func listKnowledgeGroups() async throws -> [KnowledgeGroup]
    /// GET /api/knowledge/embedding-status（独立拉取，失败不影响主面板）
    func fetchEmbeddingStatus() async throws -> EmbeddingStatus
    /// POST /api/knowledge/rebuild-index → 重建出的条目数
    @discardableResult
    func rebuildKnowledgeIndex() async throws -> KnowledgeRebuildResult
    /// POST /api/knowledge/open-dir（200 但 ok:false 时带 detail——由 VM 决定呈不呈现）
    func openKnowledgeDir(scope: String, projectId: String?) async throws -> KnowledgeOpenDirResult
    /// POST /api/knowledge/import-files（on_conflict ∈ ask/overwrite/rename/skip）
    func importKnowledgeFiles(scope: String, projectId: String?, paths: [String],
                              onConflict: String) async throws -> KnowledgeImportResult
}
