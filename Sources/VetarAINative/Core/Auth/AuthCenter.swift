//
//  AuthCenter.swift
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

//  全局授权中心：任何面板的 SSE 流收到 auth_request 事件，都统一交给本中心：
//    ① 命中会话记忆表（「本会话不再询问」留下的）→ 不弹窗，自动回 allowed=true
//    ② 否则弹出全局授权弹窗（RootView 顶层 overlay），用户点按钮后回传结论
//
//  记忆两级（语义对齐 0.4.34 / R2 0.4.33）：
//    · 会话级：app 内内存表（AuthMemoryKey 集合），app 重启即失效；
//      同时把 remember:"session" 回传后端（双保险，后端也有自己的会话记忆）。
//    · 永久级：只回传 remember:"always"，由后端 config 持久化；app 不本地存。
//    · 联网安装（net_install）不显示记忆按钮 —— 安全敏感，每次必问。
//
//  多请求并发：后端同一时刻只会有一个未决授权（loop 阻塞等待），
//  但防御性地排队处理，前一个未决时不覆盖。
//

import Foundation

@MainActor
public final class AuthCenter: ObservableObject {

    /// 当前待决的授权请求（驱动全局弹窗）；nil = 无弹窗。
    @Published public private(set) var pending: AuthPrompt?

    /// 会话级记忆表（app 内内存，重启失效）。
    public private(set) var sessionMemory: Set<AuthMemoryKey> = []

    private var queue: [AuthPrompt] = []
    private let logger: AppLogger
    /// 取当前可用的内核客户端（原生装配；为 nil 时弹窗仍在但回传会失败并记日志）。
    private let clientProvider: () -> SidecarClientProtocol?

    public init(logger: AppLogger = .shared,
                clientProvider: @escaping () -> SidecarClientProtocol? = { nil }) {
        self.logger = logger
        self.clientProvider = clientProvider
    }

    // MARK: - 入口：SSE 事件

    /// 面板 SSE 分发器收到 auth_request 时调用（纪律③：调用前请先 flush 增量缓冲）。
    public func handle(event: SSEEvent) {
        guard let prompt = AuthPrompt(event: event) else {
            logger.log(.warn, "auth_request 缺 request_id，忽略：\(event.rawData.prefix(200))")
            return
        }
        // 会话记忆命中 → 不弹窗，自动允许
        if prompt.showsRememberButtons && sessionMemory.contains(prompt.memoryKey) {
            logger.log(.info, "授权会话记忆命中，自动允许：\(prompt.memoryKey)")
            Task { await self.respond(prompt, allowed: true, remember: nil) }
            return
        }
        present(prompt)
    }

    /// 直接呈递一条授权请求（测试 / 调试 mock 入口）。
    public func present(_ prompt: AuthPrompt) {
        if pending == nil {
            pending = prompt
        } else {
            queue.append(prompt)
        }
        logger.log(.info, "授权请求呈递：action=\(prompt.action) tool=\(prompt.toolName) id=\(prompt.id)")
    }

    // MARK: - 出口：用户决策

    /// 用户对当前弹窗的决策。
    /// - Parameters:
    ///   - allowed: 允许 / 拒绝
    ///   - remember: 记忆级别（nil = 仅本次）
    ///   - enableNetwork: 联网安装附带「同时开启全量联网」勾选值
    public func decide(allowed: Bool, remember: AuthRemember? = nil, enableNetwork: Bool = false) async {
        guard let prompt = pending else { return }
        pending = nil
        // 会话记忆落表（仅允许路径；拒绝谈不上「不再询问」，对齐前端 rmMode 仅确认路径回传）
        if allowed, remember == .session {
            sessionMemory.insert(prompt.memoryKey)
        }
        await respond(prompt, allowed: allowed, remember: remember, enableNetwork: enableNetwork)
        // 队列下一条递补
        if !queue.isEmpty {
            pending = queue.removeFirst()
        }
    }

    /// 回传后端：POST /api/auth/respond。remember 缺省 = 仅本次（键省略）。
    public func respond(_ prompt: AuthPrompt, allowed: Bool,
                        remember: AuthRemember?, enableNetwork: Bool = false) async {
        guard let client = clientProvider() else {
            logger.log(.error, "授权回传失败：内核客户端不可用（request_id=\(prompt.id)）")
            return
        }
        let body = AuthRespondRequest(
            request_id: prompt.id,
            allowed: allowed,
            enable_network: allowed && enableNetwork,
            remember: remember?.rawValue
        )
        do {
            try await client.respondAuth(body)
            logger.log(.info, "授权已回传：id=\(prompt.id) allowed=\(allowed) remember=\(remember?.rawValue ?? "仅本次")")
        } catch {
            logger.log(.error, "授权回传失败：\(SidecarError.describe(error))")
        }
    }

    // MARK: - 记忆表管理

    public func isRemembered(_ key: AuthMemoryKey) -> Bool { sessionMemory.contains(key) }

    /// 清空会话记忆（新会话 / 用户主动重置时调用）。
    public func clearSessionMemory() { sessionMemory.removeAll() }

    // MARK: - 调试 mock（冒烟截图 / 后续波次联调用）

    /// 构造一条 mock 授权请求并呈递。仅在 VETARAI_DEBUG_AUTH_MOCK=1
    /// 或命令行带 --debug-auth-mock 时可从 UI 触发（见基础设置底部「诊断」区；
    /// 0.7.1 Bug 7 前在 AboutPanel 调试区）。
    public func presentMock(netInstall: Bool = false) {
        let prompt: AuthPrompt
        if netInstall {
            prompt = AuthPrompt(
                id: "mock-\(UUID().uuidString.prefix(8))",
                action: "net_install",
                toolName: "install_skill",
                targetPath: "https://github.com/example/skill-pack",
                extra: ["install_type": "技能包",
                        "source_url": "https://github.com/example/skill-pack",
                        "need_enable_network": true]
            )
        } else {
            prompt = AuthPrompt(
                id: "mock-\(UUID().uuidString.prefix(8))",
                action: "delete",
                toolName: "fs_delete",
                targetPath: "~/Library/Application Support/VetarAINative/SidecarData/pilot-sandbox/tmp.txt",
                extra: [:]
            )
        }
        present(prompt)
    }

    /// 调试开关是否打开（环境变量或命令行参数）。
    public static var debugMockEnabled: Bool {
        ProcessInfo.processInfo.environment["VETARAI_DEBUG_AUTH_MOCK"] == "1"
            || CommandLine.arguments.contains("--debug-auth-mock")
    }
}
