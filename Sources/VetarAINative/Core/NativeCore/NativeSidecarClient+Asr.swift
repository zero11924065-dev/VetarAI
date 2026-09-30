//
//  NativeSidecarClient+Asr.swift
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

//  AsrPanelClient 的原生实现：两端点全部走 NativeKernel.asrEndpoints
//  （NativeAsrEndpoints 装配体，app.py L2917-3027 逐行为移植）：
//    · status 永不抛——三态体本身就是容错契约（ready/disabled/none 200 返回），
//      原生侧同步直出；
//    · transcribe 的 400/409/422 错误已由端点层包装成 SidecarError.httpError
//      （与 HTTP 层同形——调用方 ViewModel 零改动）。
//

import Foundation

extension NativeSidecarClient: AsrPanelClient {

    /// GET /api/asr/status 等价（app.py L2917-2946）：三态 ready/disabled/none，永不 5xx。
    public func fetchAsrStatus() async throws -> AsrStatusInfo {
        kernel.asrEndpoints.status()
    }

    /// POST /api/asr/transcribe 等价（app.py L2960-3027）：400 校验链七步逐字；
    /// PackUnavailable→409 / AudioDecode→422 / ValueError→400；C7 落盘降级。
    public func transcribeAsrAudio(path: String, packId: String?, language: String,
                                   projectId: String, sessionId: String) async throws -> AsrTranscribeOutcome {
        try await kernel.asrEndpoints.transcribe(path: path, packId: packId, language: language,
                                                 projectId: projectId, sessionId: sessionId)
    }
}
