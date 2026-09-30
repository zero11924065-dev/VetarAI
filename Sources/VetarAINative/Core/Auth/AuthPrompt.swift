//
//  AuthPrompt.swift
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

//  授权请求模型 + 弹窗文案构建。
//  语义逐条对齐 subagent/renderer/src/panels/ChatPanel.tsx 的 auth_request 分支
//  （0.4.34 口径）与 Dialog.tsx（R2 0.4.33 记忆按钮）：
//    · 四类分支：net_install（联网安装）/ app_module（应用内模块）/
//      computer_use（操作电脑）/ 其他（敏感路径读写删除等）
//    · 按钮固定为「拒绝 / 本会话不再询问 / 永久允许 / 允许」（允许文案随分支变化）
//    · net_install 不显示记忆按钮 —— 安全敏感，每次必问；可按 extra.need_enable_network
//      附带「同时开启全量联网」勾选
//

import Foundation

/// 授权记忆键：会话级记忆的最小粒度 = 动作类别 × 工具名。
/// 刻意不含 target_path —— 「删除 ~/Documents 下文件」类授权的记忆应对该
/// 动作类别整体生效，而不是逐文件再问一遍（与前端后端记忆语义一致）。
public struct AuthMemoryKey: Hashable, Sendable {
    public let action: String
    public let toolName: String

    public init(action: String, toolName: String) {
        self.action = action
        self.toolName = toolName
    }
}

/// 一条待决授权请求（来自 SSE auth_request 事件）。
public struct AuthPrompt: Identifiable {
    /// request_id（回传 /auth/respond 用）
    public let id: String
    public let action: String        // delete/write/mkdir/read/list/net_install/app_module/computer_use/...
    public let toolName: String
    public let targetPath: String
    /// extra 原文（install_type/source_url/need_enable_network/module/action/params/desc/app/args）
    public let extra: [String: Any]

    public init(id: String, action: String, toolName: String, targetPath: String,
                extra: [String: Any] = [:]) {
        self.id = id
        self.action = action
        self.toolName = toolName
        self.targetPath = targetPath
        self.extra = extra
    }

    /// 从 SSE 事件构建；缺 request_id 返回 nil（无法回传，记日志忽略）。
    public init?(event: SSEEvent) {
        guard let rid = event.string("request_id"), !rid.isEmpty else { return nil }
        self.init(
            id: rid,
            action: event.string("action") ?? "operate",
            toolName: event.string("tool_name") ?? "未知工具",
            targetPath: event.string("target_path") ?? "未知路径",
            extra: event.data["extra"] as? [String: Any] ?? [:]
        )
    }

    // MARK: - 分支判定（对齐前端）

    public var isNetInstall: Bool { action == "net_install" }
    public var isAppModule: Bool { action == "app_module" }
    public var isComputerUse: Bool { action == "computer_use" }

    /// 联网安装类不显示记忆按钮（安全敏感，每次必问）。
    public var showsRememberButtons: Bool { !isNetInstall }

    /// 会话记忆键。
    public var memoryKey: AuthMemoryKey { AuthMemoryKey(action: action, toolName: toolName) }

    /// 动作中文标签（对齐前端 actionLabel 映射）。
    public var actionLabel: String {
        switch action {
        case "computer_use": return "操作电脑"
        case "app_module": return "调用应用模块"
        case "net_install": return "联网安装"
        case "delete": return "删除"
        case "write": return "写入"
        case "mkdir": return "新建目录"
        case "read": return "读取"
        case "list": return "列出"
        default: return action
        }
    }

    // MARK: - 弹窗文案（标题 / 正文 / 确认按钮 / 危险态 / 联网勾选）

    public var dialogTitle: String {
        if isNetInstall { return "联网安装确认" }
        if isAppModule { return "应用模块操作确认" }
        if isComputerUse { return "电脑操作确认" }
        return "操作授权"
    }

    public var confirmLabel: String {
        if isNetInstall { return "允许安装" }
        if isAppModule || isComputerUse { return "允许执行" }
        return "允许"
    }

    /// 前端四类分支全部用 danger: true（确认按钮红色）。
    public var isDanger: Bool { true }

    /// 「同时开启全量联网」勾选（仅 net_install 且后端提示需要时）。
    public var showsEnableNetworkCheckbox: Bool {
        isNetInstall && (extra["need_enable_network"] as? Bool ?? false)
    }

    public static let enableNetworkCheckboxLabel =
        "同时开启全量联网（切换到「全量」模式，经代理访问海外站点）"

    public var dialogMessage: String {
        if isNetInstall {
            let installType = extra["install_type"] as? String ?? "内容"
            let source = extra["source_url"] as? String ?? targetPath
            return """
            Agent 请求联网下载并安装\(installType)：

            来源：\(source)

            ⚠️ 这会从外部仓库下载代码并装入应用。请确认来源可信后再允许；拒绝则不联网、不安装。
            """
        }
        if isAppModule {
            let mod = extra["module"] as? String ?? "?"
            let act = extra["action"] as? String ?? "?"
            let params = Self.truncatedJSON(extra["params"], limit: 600)
            return """
            Agent 请求调用应用内模块：

            模块：\(mod)
            动作：\(act)

            参数：
            \(params)

            该操作成本较高（会运行工作流或创建圆桌讨论、占用模型与内存），是否允许？
            """
        }
        if isComputerUse {
            let desc = extra["desc"] as? String ?? "操作电脑"
            let app = extra["app"] as? String ?? "（未知前台应用）"
            let args = Self.truncatedJSON(extra["args"], limit: 500)
            return """
            Agent 请求\(desc)：

            当前前台应用：\(app)
            参数：
            \(args)

            ⚠️ 这会真实操作你的电脑（鼠标/键盘），效果立即可见且可能难以撤销。确认要执行吗？
            """
        }
        return """
        Agent 请求\(actionLabel)敏感位置的内容：

        \(targetPath)

        工具：\(toolName)

        该操作位于系统敏感区域，是否允许？
        """
    }

    private static func truncatedJSON(_ value: Any?, limit: Int) -> String {
        guard let value else { return "{}" }
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted]),
              var text = String(data: data, encoding: .utf8) else {
            return "（参数无法显示）"
        }
        if text.count > limit {
            text = String(text.prefix(limit)) + "\n…（已截断）"
        }
        return text
    }
}
