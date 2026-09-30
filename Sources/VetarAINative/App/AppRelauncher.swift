//
//  AppRelauncher.swift
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

//  口径（拍板）：
//    · 重启不丢数据——调用方（AppState.restartApp）先按 W8 红线暂停在飞工作室
//      会话（优雅取消 + 落盘 flush + 快照同步写），本工具只负责进程重生；
//    · 下载中断重启恢复由 NativeRequiredModels 持久化承担（downloading →
//      notDownloaded，.part 在盘续传；ready/failed 原样），与本工具无关。
//    · 保留启动参数重生：冒烟/诊断依赖 -sidecar.dataRoot 等 CLI 覆盖，
//      直接 posix_spawn 可执行文件（不经 open(1)/LaunchServices——open 会丢
//      进程参数且与未退出实例抢 LaunchServices 单实例语义）。
//    · 延迟 1.2s 重生：等本进程 terminate 走完（落盘/锁释放），避免双实例
//      短暂并抢 dataRoot。
//

import AppKit

public enum AppRelauncher {

    /// 以当前进程同款参数延迟重生新实例，随后退出本进程。
    /// 返回与否取决于 terminate 是否被拦截（正常不返回）。
    public static func relaunchPreservingArguments(delay: TimeInterval = 1.2) {
        let exe = Bundle.main.executableURL
            ?? URL(fileURLWithPath: CommandLine.arguments.first ?? "")
        let args = Array(CommandLine.arguments.dropFirst())
        let quoted = ([exe.path] + args).map(Self.shellQuote).joined(separator: " ")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        // nohup 脱钩：本进程退出后子进程不被带走；输出归零免残留 pipe
        p.arguments = ["-c", "sleep \(delay); nohup \(quoted) >/dev/null 2>&1 &"]
        try? p.run()
        NSApp.terminate(nil)
    }

    /// POSIX 单引号包裹（内嵌单引号 '\'' 转义）
    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
