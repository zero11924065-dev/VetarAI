//
//  SidecarClient+Projects.swift
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

//  项目组面板扩展端点。沿用 Wave 1/2 子协议分层（不改 SidecarClientProtocol 声明，
//  并行波次共享该文件）：ProjectsPanelClient 收项目组面板端点，
//  生产实现 = NativeSidecarClient；面板测试用自己的 mock。
//  HTTP 扩展实现已于 P3-W6 随侧车归零退役删除。
//
//  端点契约逐条对照 subagent/sidecar/app.py（行号为移植时核对位置）：
//    GET    /api/projects                            L312  项目列表（复用 Wave 0 listProjects）
//    POST   /api/projects                            L297  建项目 {name, working_dir}（复用 createProject）
//    PUT    /api/projects/{pid}                      L820  改名 {name}；404 detail=项目不存在
//    DELETE /api/projects/{pid}                      L316  删项目（连对话/Agent/任务数据；工作目录文件不动）
//    POST   /api/projects/{pid}/export-workgroup     L1950 工作组 JSON 导出 → {ok, path, name}；404 detail
//    POST   /api/projects/open-working-dir           L2704 在 Finder 打开项目工作目录 {project_id}
//                                                      → {ok, dir, detail?}；400/404 detail
//
//  说明（原生映射决策）：现状 ProjectPanel.tsx 的目录选择链是
//  「Electron 原生选择器 → 侧车 POST /api/dialog/choose-dir（osascript）→ 内联手动输入」。
//  原生 app 恒有 NSOpenPanel（等价 Electron 分支），故不调 choose-dir 端点；
//  选择器不可用（测试/异常）时同样落内联手动输入（manualMode 语义保留）。
//

import Foundation

// MARK: - 契约模型

/// PUT /api/projects/{pid} 请求体（M5/TS-111 行内改名）。
public struct ProjectRenameRequest: Encodable {
    public let name: String
    public init(name: String) { self.name = name }
}

/// POST /api/projects/{pid}/export-workgroup 响应（TS-121 0.3.1 补遗2）。
public struct WorkgroupExportResult: Equatable {
    public let ok: Bool
    /// 导出文件绝对路径（UI 只展示其所在目录，对齐 TSX `String(d.path).replace(/\/[^/]*$/, '')`）
    public let path: String
    /// 导出文件基名（提示文案用）
    public let name: String

    public init(ok: Bool, path: String, name: String) {
        self.ok = ok
        self.path = path
        self.name = name
    }
}

/// POST /api/projects/open-working-dir 响应（0.4.5）。
/// 非 macOS / 超时等软失败：HTTP 200 但 ok=false + detail（对齐后端 L2720/L2725 分支）。
public struct OpenWorkingDirResult: Equatable {
    public let ok: Bool
    public let dir: String
    public let detail: String?

    public init(ok: Bool, dir: String, detail: String?) {
        self.ok = ok
        self.dir = dir
        self.detail = detail
    }
}

// MARK: - 子协议

public protocol ProjectsPanelClient: SidecarClientProtocol {
    /// PUT /api/projects/{pid}：改名（空名由面板拦截，不发请求；404 → httpError）。
    func renameProject(projectId: String, name: String) async throws

    /// DELETE /api/projects/{pid}：删项目（后端连删其数据目录；工作目录文件不动）。
    func deleteProject(projectId: String) async throws

    /// POST /api/projects/{pid}/export-workgroup：工作组 JSON 导出。
    func exportWorkgroup(projectId: String) async throws -> WorkgroupExportResult

    /// POST /api/projects/open-working-dir：在 Finder 打开项目工作目录。
    /// 软失败（ok=false）不抛错，由面板读 detail 上屏。
    func openWorkingDir(projectId: String) async throws -> OpenWorkingDirResult
}

// MARK: - W5b 共享错误文案助手

public extension SidecarError {
    /// TSX apiJson 口径：FastAPI 错误只上屏 detail（不带 HTTP 前缀）；非 HTTP 错误走 describe。
    /// 现状面板文案（'创建失败: ' + e.message 等）的 e.message 即 detail，本 helper 对齐该形态。
    static func detailText(_ error: Error) -> String {
        if case SidecarError.httpError(_, let detail) = error, !detail.isEmpty {
            return detail
        }
        return SidecarError.describe(error)
    }
}
