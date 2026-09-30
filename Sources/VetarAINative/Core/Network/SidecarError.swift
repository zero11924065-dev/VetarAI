//
//  SidecarError.swift
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

//  统一错误类型：所有面板共享同一套错误语义，UI 层用 describe 转人话。
//

import Foundation

public enum SidecarError: Error, Equatable {
    /// 后端返回非 2xx；detail 已从 FastAPI {"detail": ...} 体提取（字符串或 422 对象数组）。
    case httpError(status: Int, detail: String)
    /// 响应不是 HTTP 响应（协议层异常）。
    case invalidResponse
    /// 响应体解码失败（契约漂移信号，附响应前 200 字符）。
    case decodeFailed(String)
    /// 请求超时（URLRequest.timeoutInterval 触发）。
    case timeout
    /// 网络层失败（主机不可达 / 连接被重置等 URLError）。
    case offline(String)

    /// 人话描述（UI 直接展示）。
    public static func describe(_ error: Error) -> String {
        if case SidecarError.httpError(let status, let detail) = error {
            return "HTTP \(status)：\(detail)"
        }
        if case SidecarError.timeout = error {
            return "请求超时"
        }
        if case SidecarError.offline(let msg) = error {
            return "连接失败：\(msg)"
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut: return "请求超时"
            case .cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet:
                return "连接失败：内核不可用"
            default: break
            }
        }
        return error.localizedDescription
    }
}
