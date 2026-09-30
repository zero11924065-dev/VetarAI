//
//  NativeCUMacroEndpoints.swift
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

//  逐行为移植（⛔ 只读行为规格源：subagent/sidecar/app.py L2453-2552 +
//  computer_use/cu_macro.py + computer_use/user_recorder.py）：
//    · GET    /api/cu-macros（L2453-2462）：摘要列表 + recording /
//      recording_steps（0.4.33 F2）/ recording_mode（0.4.34 R4，nil|"agent"|"user"）
//    · GET    /api/cu-macros/user-record/permission（L2465-2471）：
//      「输入监控」TCC 状态（只读状态位；bool(g)——探测不到 None → false）
//    · POST   /api/cu-macros/user-record/permission/request（L2474-2480）：
//      触发系统授权弹窗并返回弹窗后状态（系统只弹一次；允许后需重启进程生效）
//    · POST   /api/cu-macros/record/start（L2483-2499）：错误映射
//      input_monitoring_not_granted→403 / replay_busy 或 conflict→409 / 其余→422
//    · POST   /api/cu-macros/record/stop（L2502-2516）：未录制→422；0 步空宏
//      → 200 {saved:false, steps:0, message} 不发通知；saved:true → A13 create
//    · POST   /api/cu-macros/{id}/replay（L2519-2532）：not_found→404 /
//      user_recording_busy→409 / 其余（empty_macro/replay_busy…）→422
//    · GET    /api/cu-macros/replays/{run_id}（L2535-2542）：404「回放记录不存在」
//    · DELETE /api/cu-macros/{id}（L2545-2552）：404「宏不存在或已删除」→ A13 delete
//
//  TCC 重归属（P3-W4 拍板）：「输入监控」授权主体从 Python 侧车二进制
//  （com.vetarai.sidecar）转为原生 app 可执行文件（ai.vetar.native）——
//  权限两端点查/请的都是原生进程自身的状态位；未授权引导文案
//  （_input_monitoring_error）逐字对齐 Python，二进制路径换成本进程。
//

import Foundation

public final class NativeCUMacroEndpoints: @unchecked Sendable {

    public let store: NativeCUMacroStore
    /// 「输入监控」TCC 探针（user_recorder.listen_access_granted /
    /// request_listen_access 同构；生产 = NativeUserRecorder 真探针；测试注入假探针）。
    public var listenAccessGranted: @Sendable () -> Bool?
    public var requestListenAccess: @Sendable () -> Bool

    public init(store: NativeCUMacroStore) {
        self.store = store
        self.listenAccessGranted = { NativeUserRecorder.listenAccessGranted() }
        self.requestListenAccess = { NativeUserRecorder.requestListenAccess() }
    }

    private func httpError(_ status: Int, _ detail: String) -> SidecarError {
        .httpError(status: status, detail: detail)
    }

    // MARK: - GET /api/cu-macros（L2453-2462）

    public func list() -> CuMacroListState {
        CuMacroListState(
            macros: store.listMacros().map {
                CuMacroSummary(id: $0.id, name: $0.name, created_at: $0.createdAt,
                               steps: $0.steps)
            },
            recording: store.isRecording(),
            recordingSteps: store.recordingSteps(),
            recordingMode: store.recordingMode())
    }

    // MARK: - GET /api/cu-macros/user-record/permission（L2465-2471）

    /// bool(g)：None（探测不到）→ false。
    public func userRecordPermission() -> CuUserRecordPermission {
        CuUserRecordPermission(granted: listenAccessGranted() ?? false)
    }

    // MARK: - POST /api/cu-macros/user-record/permission/request（L2474-2480）

    public func requestUserRecordPermission() -> CuUserRecordPermission {
        CuUserRecordPermission(granted: requestListenAccess())
    }

    // MARK: - POST /api/cu-macros/record/start（L2483-2499）

    /// 错误映射逐字（L2492-2498）；成功返回后端登记的宏名（可能被截断，UI 以服务端名为准）。
    @discardableResult
    public func recordStart(name: String, mode: String?) throws -> String {
        let r = store.startRecording(name: name, mode: mode ?? "agent")
        guard r["ok"]?.bool == true else {
            let err = r["error"]?.string ?? ""
            if err.hasPrefix("input_monitoring_not_granted") {
                throw httpError(403, err)
            }
            if err.hasPrefix("replay_busy") || r["conflict"]?.bool == true {
                throw httpError(409, err)
            }
            throw httpError(422, err)
        }
        return r["name"]?.string ?? ""
    }

    // MARK: - POST /api/cu-macros/record/stop（L2502-2516）

    public func recordStop() throws -> CuMacroStopResult {
        let r = store.stopRecording()
        guard r["ok"]?.bool == true else {
            throw httpError(422, r["error"]?.string ?? "")
        }
        if r["saved"]?.bool == false {
            // 0 步空宏：不落盘、不发创建通知（L2511-2513）
            return CuMacroStopResult(saved: false, steps: 0,
                                     message: r["message"]?.string ?? "未捕获到任何动作，宏未保存")
        }
        // A13（L2515）：cu_macro/create 带 macro_id
        if case .object(let m)? = r["macro"], let mid = m["id"]?.string {
            NativeEndpointNotify.change(NativeAppEvents.resourceCuMacro,
                                        NativeAppEvents.actionCreate,
                                        extra: ["macro_id": .string(mid)])
        }
        // saved:true 响应无顶层 steps 键（L2516 {ok, saved, macro}）——HTTP 客户端
        // 缺键按 0 兜底，原生同口径（面板仅 saved:false 分支消费 steps）
        return CuMacroStopResult(saved: true, steps: 0, message: nil)
    }

    // MARK: - POST /api/cu-macros/{macro_id}/replay（L2519-2532）

    @discardableResult
    public func replay(macroId: String) throws -> String {
        let r = store.startReplay(macroId: macroId)
        guard r["ok"]?.bool == true, let runId = r["run_id"]?.string else {
            let err = r["error"]?.string ?? ""
            if err == "not_found" {
                throw httpError(404, "宏不存在或已删除")
            }
            if err.hasPrefix("user_recording_busy") {
                throw httpError(409, err)
            }
            throw httpError(422, err)
        }
        return runId
    }

    // MARK: - GET /api/cu-macros/replays/{run_id}（L2535-2542）

    public func replayStatus(runId: String) throws -> CuReplayRun {
        guard let run = store.getRun(runId) else {
            throw httpError(404, "回放记录不存在")
        }
        return CuReplayRun(
            run_id: run.runId, macro_id: run.macroId, macro_name: run.macroName,
            status: run.status, total: run.total, completed: run.completed,
            failed_seq: run.failedSeq, error: run.error,
            steps: run.steps.map { s in
                CuReplayStep(seq: Int(s["seq"]?.int ?? s["seq"]?.double.map { Int64($0) } ?? 0),
                             action: s["action"]?.string ?? "",
                             method: s["method"]?.string ?? "",
                             ok: s["ok"]?.bool ?? false,
                             error: s["error"]?.string)
            })
    }

    // MARK: - 全程审计聚合（0.7.4 W5 新增只读面；app.py 无对应端点——原生加成，
    //   支撑面板「命中率全程审计」行，与「最近一次回放口径」hitRate 并存）

    /// 命中率全程审计：进程内运行记录按宏聚合（回放数/成功数/元素命中/像素回落）。
    /// ⚠️ 进程内口径：重启即空、RUNS_KEPT=50 上限——不是持久历史。
    public func auditSummary() -> [CuMacroAuditEntry] {
        store.macroAuditSummary().map {
            CuMacroAuditEntry(id: $0.macroId, name: $0.macroName, replays: $0.replays,
                              successes: $0.successes, element_hits: $0.elementHits,
                              pixel_fallbacks: $0.pixelFallbacks)
        }
    }

    // MARK: - DELETE /api/cu-macros/{macro_id}（L2545-2552）

    public func deleteMacro(macroId: String) throws {
        guard store.deleteMacro(macroId) else {
            throw httpError(404, "宏不存在或已删除")
        }
        // A13（L2551）：cu_macro/delete 带 macro_id
        NativeEndpointNotify.change(NativeAppEvents.resourceCuMacro,
                                    NativeAppEvents.actionDelete,
                                    extra: ["macro_id": .string(macroId)])
    }
}
