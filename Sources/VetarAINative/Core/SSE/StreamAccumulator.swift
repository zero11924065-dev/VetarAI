//
//  StreamAccumulator.swift
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

//  ═══════════════════════════════════════════════════════════════════
//  纪律①（DBG-138）：流式渲染必经缓冲 + 定频合帧 flush（默认 15fps）。
//  token/thinking 增量若逐事件直接写 UI 状态，SwiftUI 会对不断变长的全文
//  逐 token 重排，主线程打满、整个 app 失去响应（前端 0.4.23 与 pilot
//  均实测复现：2000 行数字流直接卡死）。对齐前端 requestAnimationFrame
//  合帧：增量先落本器缓冲，按定频批量 flush 到 UI。
//
//  纪律③：非增量事件（tool_call / tool_result / done / error / cancelled /
//  auth_request / compact_* / segment_break）分发前必须先 flush() 保序 ——
//  保证「先到的增量先落地」，事件顺序与后端发出顺序一致。
//  ═══════════════════════════════════════════════════════════════════
//
//  用法（面板 ViewModel）：
//    let acc = StreamAccumulator()
//    acc.onFlush = { content, thinking in 把增量写进消息模型 }
//    // token 事件：acc.append(content: delta)；thinking 事件：acc.append(thinking: delta)
//    // 其他事件分发前：acc.flush()
//    // 流结束（done/error/cancelled/断流）：acc.flush() 后清状态
//

import Foundation

@MainActor
public final class StreamAccumulator {

    /// 合帧频率（fps）。默认 15 —— DBG-138 定频口径，不要再调高。
    public let fps: Int
    /// flush 回调：把一批正文增量与思考增量交付给 UI 层。主线程同步调用。
    public var onFlush: ((_ contentDelta: String, _ thinkingDelta: String) -> Void)?

    private var contentAcc = ""
    private var thinkingAcc = ""
    private var flushScheduled = false
    /// 测试/诊断用：已执行的 flush 次数（含空 flush 不计）。
    public private(set) var flushCount = 0

    public init(fps: Int = 15) {
        self.fps = max(1, fps)
    }

    /// 追加增量。任一参数非空即入缓冲并调度定频 flush。
    public func append(content: String = "", thinking: String = "") {
        if !content.isEmpty { contentAcc += content }
        if !thinking.isEmpty { thinkingAcc += thinking }
        guard !contentAcc.isEmpty || !thinkingAcc.isEmpty else { return }
        scheduleFlush()
    }

    /// 立即冲刷缓冲（纪律③保序点 / 流收尾）。空缓冲时为 no-op。
    public func flush() {
        flushScheduled = false
        guard !contentAcc.isEmpty || !thinkingAcc.isEmpty else { return }
        let c = contentAcc, t = thinkingAcc
        contentAcc = ""; thinkingAcc = ""
        flushCount += 1
        onFlush?(c, t)
    }

    /// 缓冲中是否还有未落地增量（调试用）。
    public var hasPending: Bool { !contentAcc.isEmpty || !thinkingAcc.isEmpty }

    // MARK: - 私有

    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        let interval = UInt64(1_000_000_000 / fps)
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: interval)
            self?.flush()
        }
    }
}
