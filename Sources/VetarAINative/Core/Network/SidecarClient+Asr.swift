//
//  SidecarClient+Asr.swift
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

//  ASR（语音转写）面板/聊天话筒扩展端点。沿用既有子协议模式：
//  生产实现 = NativeSidecarClient（NativeSidecarClient+Asr 扩展，NativeAsrEndpoints
//  装配体）；测试注入 mock。HTTP 扩展实现已于 P3-W6 随侧车归零退役删除。
//
//  端点契约逐条对照 subagent/sidecar/app.py：
//    GET  /api/asr/status      app.py:2917  → AsrStatusInfo（三态 ready/disabled/none，
//                              容错契约：任何意外也 200，永不 5xx——前端据此渲染引导）
//    POST /api/asr/transcribe  app.py:2960  → AsrTranscribeOutcome（入参 {path, pack_id?,
//                              language, project_id, session_id}；400 校验链七步逐字、
//                              PackUnavailable→409 / AudioDecode→422 / ValueError→400；
//                              C7 落盘 saved_path/save_error 降级）
//

import Foundation

// MARK: - ASR 面板客户端协议

public protocol AsrPanelClient: SidecarClientProtocol {
    /// GET /api/asr/status（永不 5xx：失败也回 200 三态体；面板据此渲染安装引导）。
    func fetchAsrStatus() async throws -> AsrStatusInfo
    /// POST /api/asr/transcribe {path, pack_id?, language, project_id, session_id}。
    /// packId nil = 后端按注册表自动选首个启用中 asr 包；projectId/sessionId 缺一
    /// 则后端不落盘附件（saved_path/save_error 双 nil）。
    func transcribeAsrAudio(path: String, packId: String?, language: String,
                            projectId: String, sessionId: String) async throws -> AsrTranscribeOutcome
}
