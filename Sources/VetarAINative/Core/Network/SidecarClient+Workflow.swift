//
//  SidecarClient+Workflow.swift
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

//  流程中心（WorkflowPanel / WorkflowEditor / WorkflowCanvas）扩展端点。
//  沿用 Wave 1/2 的子协议模式，不改 Wave 0 协议文件：
//  生产实现 = NativeSidecarClient；面板测试注入自己的 mock。
//  HTTP 扩展实现已于 P3-W6 随侧车归零退役删除。
//
//  端点契约逐条对照 subagent/sidecar/app.py（行号为移植时核对位置）：
//    GET    /api/workflows                          工作流列表（app.py:2226）
//    POST   /api/workflows                          创建 {name, description, definition}
//                                                   （app.py:2231；宽松校验，422 detail 字符串）
//    GET    /api/workflows/{id}                     单条定义（app.py:2244，404 不存在）
//    PUT    /api/workflows/{id}                     保存 {name?, description?, definition?}
//                                                   （app.py:2252；403 内置 / 422 校验失败）
//    DELETE /api/workflows/{id}                     删除（app.py:2272；403 内置；运行记录保留）
//    POST   /api/workflows/{id}/run                 运行 {params} → SSE 流（app.py:2285；
//                                                   严格校验 422；事件 node_start/node_done/
//                                                   node_error/approval_required/workflow_done/
//                                                   workflow_failed/workflow_stopped/workflow_reply…
//                                                   全部注入 run_id）
//    GET    /api/workflow-runs?workflow_id&limit    运行记录列表（app.py:2324）
//    GET    /api/workflow-runs/{id}                 运行详情（app.py:2329，含 node_events）
//    POST   /api/workflow-runs/{id}/approve         审批决议 {approved, comment}
//                                                   （app.py:2338；409 非等待审批状态）
//    POST   /api/workflow-runs/{id}/stop            停止运行（app.py:2354；
//                                                   仅 running/awaiting_approval 可停）
//    GET    /api/inference/models                   模型下拉数据源（复用 Inference 扩展实现）
//    GET    /api/events/stream?since=               A13 资源变更流（复用 Inference 扩展实现；
//                                                   resource==workflow / gap → 重拉列表）
//

import Foundation

// MARK: - 工作流面板客户端协议

public protocol WorkflowPanelClient: SidecarClientProtocol {
    /// GET /api/workflows（侧车未启动时面板按现状容错为空列表，错误在 VM 层消化）。
    func listWorkflows() async throws -> [WorkflowRecord]
    /// POST /api/workflows → 新工作流 id（422 时 httpError.detail 为校验错误串）。
    @discardableResult
    func createWorkflow(name: String, description: String, definition: WorkflowDefinition) async throws -> String
    /// GET /api/workflows/{id}（404 → httpError；面板用于必要时回读单条）。
    func getWorkflow(id: String) async throws -> WorkflowRecord
    /// PUT /api/workflows/{id}（name/description/definition 全量传 = TSX saveWorkflow 口径；
    /// 403 内置工作流 / 422 校验失败，detail 原样上屏）。
    func updateWorkflow(id: String, update: WorkflowUpdateRequest) async throws
    /// DELETE /api/workflows/{id}（运行记录保留；403 内置）。
    func deleteWorkflow(id: String) async throws
    /// POST /api/workflows/{id}/run → SSE 事件流。
    /// 事件名不走 SSEEventKind（node_*/workflow_*/approval_required 等非聊天契约事件），
    /// 面板按 SSEEvent.event 原始名分发；取消消费方 Task 即断流（对齐 abortRef.abort）。
    func runWorkflow(id: String, params: [String: JSONValue]) -> AsyncThrowingStream<SSEEvent, Error>
    /// GET /api/workflow-runs?workflow_id=&limit=（workflowId nil = 全部；limit 钳 1...100 在后端）。
    func listWorkflowRuns(workflowId: String?, limit: Int) async throws -> [WorkflowRunRecord]
    /// GET /api/workflow-runs/{id}（含 node_events；404 → httpError）。
    func getWorkflowRun(id: String) async throws -> WorkflowRunDetail
    /// POST /api/workflow-runs/{id}/approve（409 时 detail 说明当前状态）。
    func approveWorkflowRun(runId: String, approved: Bool, comment: String) async throws
    /// POST /api/workflow-runs/{id}/stop（非进行中返回 {"ok": false}，仍 2xx，不抛错）。
    func stopWorkflowRun(runId: String) async throws

    /// GET /api/inference/models（节点表单模型下拉；与 InferencePanelClient
    /// 共用同一方法，此处仅声明依赖）。
    func fetchInferenceModels() async throws -> [InferenceModelEntry]
    /// GET /api/events/stream?since=（A13 资源变更流；同上进复用）。
    func appEventsStream(since: Int) -> AsyncThrowingStream<SSEEvent, Error>
}
