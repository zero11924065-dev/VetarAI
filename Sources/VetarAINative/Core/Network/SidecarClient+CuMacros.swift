//
//  SidecarClient+CuMacros.swift
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

//  CU 任务宏面板扩展端点。沿用子协议分层：CuMacroPanelClient +
//  生产实现 = NativeSidecarClient；面板测试用自己的 mock。
//  HTTP 扩展实现已于 P3-W6 随侧车归零退役删除。
//
//  端点契约逐条对照 subagent/sidecar/app.py + computer_use/cu_macro.py（行号为移植时核对位置）：
//    GET    /api/cu-macros                              app.py L2453
//           → {ok, macros:[{id,name,created_at,steps}], recording,
//              recording_steps(0.4.33 F2，未录制 0/缺键按 0),
//              recording_mode(0.4.34 R4，null|"agent"|"user"，录制中缺键面板按 agent 兜底)}
//    GET    /api/cu-macros/user-record/permission       app.py L2465 → {ok, granted}
//    POST   /api/cu-macros/user-record/permission/request  app.py L2474 → {ok, granted}
//           （触发系统「输入监控」授权弹窗；授权按侧车二进制 com.vetarai.sidecar 记，
//             Phase 1 侧车仍是 Python 侧车，原生保持调同一组端点）
//    POST   /api/cu-macros/record/start                 app.py L2483 {name, mode?}
//           agent 模式 body 只带 name（后端缺省 mode=agent，现状零变化）；
//           403 detail 以 input_monitoring_not_granted 开头（user 未授权）；
//           409 detail already_recording/replay_busy（涉 user 互斥）；422 其余
//    POST   /api/cu-macros/record/stop                  app.py L2502
//           → saved:true {ok, saved, macro} | 0 步 {ok, saved:false, steps:0, message}；422 未在录制
//    POST   /api/cu-macros/{mid}/replay                 app.py L2519 → {ok, run_id}
//           404 宏不存在；409 user_recording_busy；422 replay_busy/empty_macro 等
//    GET    /api/cu-macros/replays/{run_id}             app.py L2535 → {ok, run}；404
//    DELETE /api/cu-macros/{mid}                        app.py L2545 → {deleted:true}；404
//
//  ⚠️ 本文件是 HTTP 回落实现（「原生内核（实验）」开关关闭时的路径）；
//  P3-W4 起路由 .native——走 NativeSidecarClient 时八端点全量原生
//  （NativeCUMacroEndpoints），「输入监控」TCC 主体 = 原生 app（ai.vetar.native）；
//  仅 HTTP 回落路径的授权主体仍是侧车二进制（com.vetarai.sidecar，上行 L15-16
//  的授权弹窗注释亦仅指回落路径）。
//

import Foundation

// MARK: - 契约模型

/// 宏列表摘要（与 cu_macro.list_macros 一致：steps 是步骤数）。
public struct CuMacroSummary: Decodable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let created_at: String
    public let steps: Int

    public init(id: String, name: String, created_at: String, steps: Int) {
        self.id = id
        self.name = name
        self.created_at = created_at
        self.steps = steps
    }
}

/// GET /api/cu-macros 响应（列表 + 录制态快照）。
public struct CuMacroListState: Equatable {
    public var macros: [CuMacroSummary]
    public var recording: Bool
    /// 0.4.33 F2：录制中已捕获步数（未录制/缺键 = 0）
    public var recordingSteps: Int
    /// 0.4.34 R4：原始 recording_mode（"agent"/"user"/nil）；录制中缺键的 agent 兜底在面板层
    public var recordingMode: String?

    public init(macros: [CuMacroSummary], recording: Bool,
                recordingSteps: Int, recordingMode: String?) {
        self.macros = macros
        self.recording = recording
        self.recordingSteps = recordingSteps
        self.recordingMode = recordingMode
    }
}

/// 回放步骤明细（cu_macro._step_finish 落 run["steps"] 的结构）。
public struct CuReplayStep: Decodable, Equatable {
    public let seq: Int
    public let action: String
    public let method: String      // element / pixel_fallback / payload / abort
    public let ok: Bool
    public let error: String?

    public init(seq: Int, action: String, method: String, ok: Bool, error: String? = nil) {
        self.seq = seq
        self.action = action
        self.method = method
        self.ok = ok
        self.error = error
    }
}

/// 回放运行记录（cu_macro.start_replay 登记的 run 结构；宽容解码）。
public struct CuReplayRun: Decodable, Equatable {
    public let run_id: String
    public let macro_id: String
    public let macro_name: String
    public let status: String      // running | done | error
    public let total: Int
    public let completed: Int
    public let failed_seq: Int?
    public let error: String
    public let steps: [CuReplayStep]

    public init(run_id: String, macro_id: String, macro_name: String, status: String,
                total: Int, completed: Int, failed_seq: Int?, error: String, steps: [CuReplayStep]) {
        self.run_id = run_id
        self.macro_id = macro_id
        self.macro_name = macro_name
        self.status = status
        self.total = total
        self.completed = completed
        self.failed_seq = failed_seq
        self.error = error
        self.steps = steps
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        run_id = try c.decodeIfPresent(String.self, forKey: .run_id) ?? ""
        macro_id = try c.decodeIfPresent(String.self, forKey: .macro_id) ?? ""
        macro_name = try c.decodeIfPresent(String.self, forKey: .macro_name) ?? ""
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? "running"
        total = try c.decodeIfPresent(Int.self, forKey: .total) ?? 0
        completed = try c.decodeIfPresent(Int.self, forKey: .completed) ?? 0
        failed_seq = try c.decodeIfPresent(Int.self, forKey: .failed_seq)
        error = try c.decodeIfPresent(String.self, forKey: .error) ?? ""
        steps = try c.decodeIfPresent([CuReplayStep].self, forKey: .steps) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case run_id, macro_id, macro_name, status, total, completed, failed_seq, error, steps
    }
}

/// POST /api/cu-macros/record/start 请求体。
/// agent 模式 mode 必须省略（后端缺省即 agent——TSX「body 仍只有 name」现状零变化契约）。
public struct CuMacroRecordStartRequest: Encodable {
    public let name: String
    public let mode: String?

    public init(name: String, mode: String? = nil) {
        self.name = name
        self.mode = mode
    }
}

/// POST /api/cu-macros/record/stop 响应（0.4.33 F2 空宏防护契约）。
public struct CuMacroStopResult: Equatable {
    /// false = 0 步未落盘（message 原文上屏，列表无新项）；true = 已落盘
    public let saved: Bool
    public let steps: Int
    public let message: String?

    public init(saved: Bool, steps: Int, message: String?) {
        self.saved = saved
        self.steps = steps
        self.message = message
    }
}

/// GET/POST permission 响应。
public struct CuUserRecordPermission: Equatable {
    public let granted: Bool
    public init(granted: Bool) { self.granted = granted }
}

/// 宏回放全程审计聚合行（0.7.4 W5 原生加成端点；snake_case 键与契约面风格一致）。
/// ⚠️ 进程内运行记录口径（重启即空，上限 RUNS_KEPT=50 条 run），不是持久历史。
public struct CuMacroAuditEntry: Decodable, Equatable {
    public let id: String
    public let name: String
    public let replays: Int          // 回放次数
    public let successes: Int        // 其中 status==done 的次数
    public let element_hits: Int     // 全部回放步骤中 method==element 的步数
    public let pixel_fallbacks: Int  // 全部回放步骤中 method==pixel_fallback 的步数

    public init(id: String, name: String, replays: Int, successes: Int,
                element_hits: Int, pixel_fallbacks: Int) {
        self.id = id
        self.name = name
        self.replays = replays
        self.successes = successes
        self.element_hits = element_hits
        self.pixel_fallbacks = pixel_fallbacks
    }
}

// MARK: - 子协议

public protocol CuMacroPanelClient: SidecarClientProtocol {
    /// GET /api/cu-macros：宏列表 + 录制态快照（录制中轮询也走本端点，只取步数）。
    func listCuMacros() async throws -> CuMacroListState

    /// GET /api/cu-macros/user-record/permission：「输入监控」TCC 状态（只读）。
    func cuUserRecordPermission() async throws -> CuUserRecordPermission

    /// POST /api/cu-macros/user-record/permission/request：触发系统授权弹窗，返回弹窗后状态。
    @discardableResult
    func requestCuUserRecordPermission() async throws -> CuUserRecordPermission

    /// POST /api/cu-macros/record/start：开始录制。mode=nil 走后端缺省 agent。
    /// 失败 → SidecarError.httpError（403 input_monitoring_not_granted / 409 互斥 / 422）。
    /// 成功返回后端登记的宏名（可能被截断，UI 以服务端名为准）。
    @discardableResult
    func startCuMacroRecording(name: String, mode: String?) async throws -> String

    /// POST /api/cu-macros/record/stop：停止录制（0 步 → saved:false 不抛错）。
    func stopCuMacroRecording() async throws -> CuMacroStopResult

    /// POST /api/cu-macros/{mid}/replay：异步回放，返回 run_id（后台线程执行真实键鼠）。
    @discardableResult
    func replayCuMacro(macroId: String) async throws -> String

    /// GET /api/cu-macros/replays/{run_id}：回放状态（面板轮询）。
    func cuMacroReplayStatus(runId: String) async throws -> CuReplayRun

    /// DELETE /api/cu-macros/{mid}：删除宏（404 → httpError）。
    func deleteCuMacro(macroId: String) async throws

    /// 宏回放全程审计聚合（0.7.4 W5 原生加成只读面；进程内运行记录口径）。
    func cuMacroAuditSummary() async throws -> [CuMacroAuditEntry]
}

extension CuMacroPanelClient {
    /// 默认空实现：面板测试 mock 不炸编译；生产由 NativeSidecarClient 真实覆盖。
    public func cuMacroAuditSummary() async throws -> [CuMacroAuditEntry] { [] }
}
