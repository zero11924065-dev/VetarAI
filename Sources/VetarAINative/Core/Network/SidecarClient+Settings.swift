//
//  SidecarClient+Settings.swift
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

//  设置面板扩展端点。沿用 Wave 1 子协议分层（不改 SidecarClientProtocol 声明，
//  并行波次共享该文件）：SettingsPanelClient 收设置页全部端点，
//  生产实现 = NativeSidecarClient；面板测试用自己的 mock。
//  HTTP 扩展实现已于 P3-W6 随侧车归零退役删除。
//
//  端点契约逐条对照 subagent/sidecar/app.py（行号为移植时核对位置）：
//    GET /api/config                            L259  读全量配置（探活同端点）
//    PUT /api/config                            L264  补丁写回 {键: 值} → 返回新全量；
//                                                   400 detail=校验文案 / 未知配置项
//    GET /api/inference/models                  L474  推理后端模型列表 [{name, size?, context_length?, source?}]
//    GET /api/computer-use/capabilities         L2420 CU 能力与权限探测 {ok, facts, problems, ...}
//    GET /api/sessions/{sid}/compact_log?project_id=  L696  压缩记录 {logs: [...]}（limit=3）
//

import Foundation

// MARK: - 契约模型

/// /api/inference/models 条目（ollama 带 size/context_length；0.4.30 起带 source 标注）。
public struct InferenceModelItem: Sendable, Equatable, Identifiable {
    public let name: String
    public let size: Int64?
    public let contextLength: Int?
    /// 0.4.30：ollama / openai_compatible / model_pack
    public let source: String?

    public var id: String { name }

    public init(name: String, size: Int64? = nil, contextLength: Int? = nil, source: String? = nil) {
        self.name = name
        self.size = size
        self.contextLength = contextLength
        self.source = source
    }
}

/// /api/computer-use/capabilities 响应（facts 键值原样保留，展示层取已知键）。
public struct CUCapabilities: Sendable, Equatable {
    public let ok: Bool
    public let problems: [String]
    /// 已知键：frontmost_app / screen_points / screenshot_px / retina_scale /
    /// accessibility_trusted / screen_capture_access / coregraphics（均可缺省 → 三态显示）。
    public let facts: [String: JSONValue]

    public init(ok: Bool, problems: [String], facts: [String: JSONValue]) {
        self.ok = ok
        self.problems = problems
        self.facts = facts
    }

    /// 三态布尔展示（true=✓ 已授予 / false=✗ 未授予 / nil=？无法探测）。
    public func factBool(_ key: String) -> Bool? { facts[key]?.bool }
    public func factString(_ key: String) -> String? {
        let v = facts[key]
        return v?.string ?? v?.int.map { String($0) } ?? v?.double.map { String($0) }
    }
}

/// 压缩记录条目（load_compact_log 行；字段宽容解码）。
public struct CompactLogEntry: Sendable, Equatable, Identifiable {
    public let ts: String
    public let beforeTokens: Int?
    public let afterTokens: Int?
    public let archivePath: String?
    public let error: String?

    public var id: String { "\(ts)-\(beforeTokens ?? -1)-\(afterTokens ?? -1)" }

    public init(ts: String, beforeTokens: Int?, afterTokens: Int?, archivePath: String?, error: String?) {
        self.ts = ts
        self.beforeTokens = beforeTokens
        self.afterTokens = afterTokens
        self.archivePath = archivePath
        self.error = error
    }
}

// MARK: - 子协议

public protocol SettingsPanelClient: SidecarClientProtocol {
    /// GET /api/config：读全量配置（未知键由 SidecarConfig 原样保留）。
    func getConfig() async throws -> SidecarConfig

    /// PUT /api/config：补丁写回（只含要改的键），返回后端合并后的新全量配置。
    /// 校验失败/未知键 → SidecarError.httpError(400, detail)（detail 为后端原文案）。
    @discardableResult
    func updateConfig(_ patch: [String: JSONValue]) async throws -> SidecarConfig

    /// GET /api/inference/models：当前推理后端可用模型（失败时面板回退手动输入）。
    func listInferenceModels() async throws -> [InferenceModelItem]

    /// GET /api/computer-use/capabilities：CU 能力与权限探测（只读）。
    func computerUseCapabilities() async throws -> CUCapabilities

    /// GET /api/sessions/{sid}/compact_log?project_id=：最近压缩记录。
    func compactLog(projectId: String, sessionId: String) async throws -> [CompactLogEntry]
}
