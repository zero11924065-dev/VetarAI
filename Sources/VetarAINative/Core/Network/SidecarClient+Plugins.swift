//
//  SidecarClient+Plugins.swift
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

//  插件管理扩展端点。沿用 Wave 1/2 子协议分层（不改 SidecarClientProtocol 声明）：
//  PluginsPanelClient 收插件面板全部端点（fetchConfig/putConfig/appEventsStream 由
//  Chat/Inference 扩展声明，此处仅重述协议要求，天然满足）；
//  生产实现 = NativeSidecarClient；面板测试注入自己的 mock。
//  HTTP 扩展实现已于 P3-W6 随侧车归零退役删除。
//
//  端点契约逐条对照 subagent/sidecar/app.py（行号为移植时核对位置）：
//    GET    /api/plugins                        L853  已装插件列表（entry_point/hooks 缺省补齐）
//    POST   /api/plugins/install                L844  {repo_url} → {success, name, version, ...}；
//           失败 400 detail=原因。远端 URL 走网络 guard（本地路径直连不 guard）
//    DELETE /api/plugins/{name}                 L863  卸载；未安装 404
//    POST   /api/plugins/{name}/toggle          L871  {enabled} → {ok, enabled}；
//           插件不存在 400
//    PUT    /api/plugins/{name}/note            L888  {note} → {ok, name, note}（空串=清除）
//    POST   /api/plugins/{name}/hooks/{hook}    L895  {agent_context} 手动触发钩子；
//           插件被禁用 403 / 无此 hook 404；返回 {result?} 或 {error?}
//
//  联网安装确认链（0.4.34 口径）：POST /api/plugins/install 本身是直接 REST，
//  授权把守在面板侧——远端 URL（http/https）每次安装前必弹「联网安装确认」，
//  不配记忆按钮（DialogCenter.confirm 本身无记忆语义）；境外来源且当前非全量联网时
//  附「同时开启全量联网」勾选（确认且勾选则先 PUT network_switch=proxy 再安装，
//  顺序不可颠倒）。本地路径不弹（后端 guard 对本地路径直连放行，loader.py L141）。
//  逻辑见 Panels/Plugins/PluginsPanelViewModel.swift installAsync。
//

import Foundation

// MARK: - 契约模型

/// 已装插件（GET /api/plugins 行；字段宽容解码，全部可缺——对齐 TSX Plugin 接口）。
public struct SidecarPlugin: Decodable, Equatable, Identifiable, Sendable {
    public let name: String
    public let version: String?
    public let entry_point: String?
    public let hooks: [String]?
    public let path: String?
    /// checkpoint-047：逐项启用开关；nil 视为启用（对齐 TSX `p.enabled === false` 判定）。
    public let enabled: Bool?
    /// 问题5（0.4.1）：用户备注（优先于 manifest description 展示）。
    public let note: String?
    /// manifest 自带描述。
    public let description: String?

    public var id: String { name }

    /// 禁用判定（对齐 TSX `const disabled = p.enabled === false`）。
    public var isDisabled: Bool { enabled == false }

    public init(name: String, version: String? = nil, entry_point: String? = nil,
                hooks: [String]? = nil, path: String? = nil, enabled: Bool? = nil,
                note: String? = nil, description: String? = nil) {
        self.name = name
        self.version = version
        self.entry_point = entry_point
        self.hooks = hooks
        self.path = path
        self.enabled = enabled
        self.note = note
        self.description = description
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let name = try c.decodeIfPresent(String.self, forKey: .name), !name.isEmpty else {
            throw DecodingError.keyNotFound(CodingKeys.name, .init(
                codingPath: decoder.codingPath, debugDescription: "SidecarPlugin.name 缺失"))
        }
        self.name = name
        version = try c.decodeIfPresent(String.self, forKey: .version)
        entry_point = try c.decodeIfPresent(String.self, forKey: .entry_point)
        hooks = try c.decodeIfPresent([String].self, forKey: .hooks)
        path = try c.decodeIfPresent(String.self, forKey: .path)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled)
        note = try c.decodeIfPresent(String.self, forKey: .note)
        description = try c.decodeIfPresent(String.self, forKey: .description)
    }

    private enum CodingKeys: String, CodingKey {
        case name, version, entry_point, hooks, path, enabled, note, description
    }
}

/// POST /api/plugins/install 响应（{"success": true, name, version, ...}，其余键忽略）。
public struct PluginInstallResult: Equatable, Sendable {
    public let name: String
    public let version: String?

    public init(name: String, version: String?) {
        self.name = name
        self.version = version
    }
}

/// 手动触发钩子的展示结果（VM 由原始响应字典映射；见 PluginsPanelViewModel.mapHookOutput）。
public struct PluginHookResult: Equatable, Sendable {
    public let ok: Bool
    public let text: String

    public init(ok: Bool, text: String) {
        self.ok = ok
        self.text = text
    }
}

// MARK: - 子协议

public protocol PluginsPanelClient: SidecarClientProtocol {
    /// GET /api/config 全量配置（联网安装确认链读 network_switch）。
    /// 与 ChatPanelClient 共用同一方法（NativeSidecarClient 单实现满足）；mock 需自供。
    func fetchConfig() async throws -> [String: Any]

    /// PUT /api/config 补丁写回（勾选「同时开启全量联网」时写 network_switch=proxy）。
    /// 与 InferencePanelClient 共用同一方法（合并语义）；mock 需自供。
    func putConfig(_ patch: [String: Any]) async throws

    /// GET /api/events/stream?since= 全局资源变更流（A13：resource=="plugin" → 重拉列表）。
    /// 与 InferencePanelClient 共用同一方法；mock 需自供。
    func appEventsStream(since: Int) -> AsyncThrowingStream<SSEEvent, Error>

    /// GET /api/plugins
    func listPlugins() async throws -> [SidecarPlugin]

    /// POST /api/plugins/install {repo_url}；失败 → httpError(400, detail)。
    @discardableResult
    func installPlugin(repoUrl: String) async throws -> PluginInstallResult

    /// DELETE /api/plugins/{name}；未安装 → httpError(404, ...)。
    func uninstallPlugin(name: String) async throws

    /// POST /api/plugins/{name}/toggle {enabled} → 返回切换后的 enabled。
    @discardableResult
    func togglePlugin(name: String, enabled: Bool) async throws -> Bool

    /// PUT /api/plugins/{name}/note {note}（空串=清除）→ 返回落库后的 note。
    @discardableResult
    func setPluginNote(name: String, note: String) async throws -> String

    /// POST /api/plugins/{name}/hooks/{hook}，body 固定
    /// {"agent_context": {"trigger": "manual", "source": "plugin_panel"}}（对齐 TSX）。
    /// 返回原始响应字典（{result?} / {error?}），展示映射在 VM。
    func triggerPluginHook(plugin: String, hook: String) async throws -> [String: Any]
}
