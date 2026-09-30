//
//  ChatWaitStage.swift
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

//  业主拍板：立项小优化（装填进度可视化/预估用时），为用户体验。
//  保守口径（⛔ 不编造精确进度）：
//    · 阶段细分只按真实信号分两段——发送→首个流事件 = 装载/装填合并段
//      （chat SSE 在首个 token 前无任何事件：Ollama/llama-server/MLX 路径
//      均无「装载完成」「prefill 完成」信号，连接器为核心域只读，不造假拆分，
//      故「模型装载中→上下文装填中」保持单阶段合并呈现）；首个 thinking/token
//      到达 = 生成已开始（真实信号）。
//    · 预估用时 = UserDefaults 记录各模型最近 5 次「发起→首 token」耗时均值；
//      有样本才显示「预计还需约 Xs」（剩余 = 均值 − 已等待，≤0 不显示），
//      无样本首用不显示，绝不编造。
//

import Foundation

/// 等待横幅阶段机（真实信号二阶段；无 prefill 细分信号，勿拆）。
public enum ChatWaitStage: String, Equatable, Sendable {
    /// 发送 → 首个流事件（模型装载 + 上下文装填合并段，无信号可细分）
    case loading
    /// 首个 thinking/token 到达（prefill 完成、生成开始——真实信号）
    case generating

    /// 横幅阶段文案（REQ-MSG-022 语境保留「已等待 Ns」口径）
    public func bannerText(waitedSeconds: Int) -> String {
        switch self {
        case .loading:
            return "模型装载/装填中，较久属正常（本地模型）…已等待 \(waitedSeconds)s"
        case .generating:
            return "生成中…已等待 \(waitedSeconds)s"
        }
    }

    /// 预估追加段：有样本且剩余 > 0 才给（≤0 静默不显示，绝不编造）。
    public static func estimateSuffix(estimate: Int?, waitedSeconds: Int) -> String {
        guard let estimate, estimate > waitedSeconds else { return "" }
        return "，预计还需约 \(estimate - waitedSeconds)s"
    }

    /// 「进行中 Ns」chip 预估追加口径（0.7.12 实测修复 F5）：
    /// 旧设计预估只挂 ≥8s 等待横幅——本地模型首 token 常 2–5s，
    /// 需 8 ≤ waited < estimate 才显示，绝大多数情况永远够不着（E2E 项11 ⏸️）。
    /// 新口径：chip 第 1 秒就可见，首 token 未到（正文仍空）即追加预估；
    /// 正文一出预估使命完成（剩余预估已无意义），自动消失。
    public static func chipSuffix(estimate: Int?, waitedSeconds: Int,
                                  contentEmpty: Bool) -> String {
        contentEmpty ? estimateSuffix(estimate: estimate, waitedSeconds: waitedSeconds) : ""
    }
}

/// 首 token 耗时样本库（UserDefaults；按模型分键，最近 maxSamples 次均值）。
/// 纯逻辑层——XCTest 注入隔离 suite 覆盖记录/均值/截尾/无样本。
public final class FirstTokenStats {

    /// 每模型保留的最近样本数（均值窗口）
    public static let maxSamples = 5

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    private func key(for model: String) -> String { "chat.firstTokenSeconds.\(model)" }

    /// 记录一次「发起→首 token」耗时（秒；空模型名/负值忽略，0s 为合法快样本）
    public func record(model: String, seconds: Int) {
        guard !model.isEmpty, seconds >= 0 else { return }
        var arr = defaults.array(forKey: key(for: model)) as? [Int] ?? []
        arr.append(seconds)
        if arr.count > Self.maxSamples { arr = Array(arr.suffix(Self.maxSamples)) }
        defaults.set(arr, forKey: key(for: model))
    }

    /// 均值预估（秒，四舍五入；无样本 → nil——首用不显示预估，绝不编造）
    public func estimate(for model: String) -> Int? {
        let arr = defaults.array(forKey: key(for: model)) as? [Int] ?? []
        guard !arr.isEmpty else { return nil }
        return Int((Double(arr.reduce(0, +)) / Double(arr.count)).rounded())
    }
}
