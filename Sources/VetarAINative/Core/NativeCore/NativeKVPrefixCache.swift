//
//  NativeKVPrefixCache.swift
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

//  依据：ROADMAP 0.7.5 W5 包（2026-09-27 业主拍板，关联 REQ-FUT-004）——
//    「KV 缓存复用/前缀共享（并行小模型同前缀会话复用已算 KV，prefill 成本
//     N 倍→1 倍+增量；llama.cpp slot 缓存与 MLX 均支持）」
//
//  本文件是可验证收益的地基（零副作用，单测全盖）：
//    · 缓存键：SHA256(modelID + prefixText)——⛔ 键必含模型 ID，
//      跨不同模型共享 KV 语义不成立（拍板红线），本层从键设计上杜绝
//    · 命中判定：token 序列公共前缀计数 + 复用阈值（minReuseTokens）
//    · 容量/TTL 策略：每引擎单槽（同模型前缀族，多槽徒增显存）+ TTL 过期
//    · 埋点契约：kind "kv.hit"/"kv.miss"，attrs 带 modelID 与 prefixHash 前 8 位
//
//  运行时落地分界（诚实）：
//    · MLX 路（NativeVModelMLXEngine）：真接——复用已算 KV（copy+trim 后只
//      prefill 增量后缀），命中/未命中经事件缝上报埋点；
//    · llama.cpp 路（NativeLlamaCppDriver）：服务端单 slot 顺序同前缀请求
//      自动复用（客户端零改动），启动参数未盲改，侦察结论登记于驱动文件头；
//    · Ollama 路：服务端自有前缀缓存（keep_alive 内同模型同前缀自动复用），
//      客户端无可开关，同登记。
//

import Foundation
import CryptoKit

// MARK: - 前缀缓存策略（纯函数）

public enum NativeKVPrefixPolicy {

    /// 复用阈值：公共前缀低于此 token 数不复用（trim/记账成本不抵收益；
    /// 32 ≈ 一条短 system 提示的量级——身份注入/系统前缀远超此值，稳命中）
    public static let minReuseTokens = 32
    /// 单槽缓存 TTL（秒）：超期丢弃（长间隔会话语义漂移风险归零；
    /// RotatingKVCache 场景同时防「轮换后不可裁」态的惰性滞留）
    public static let defaultTTLSeconds: Double = 600

    /// 埋点 kind 契约（StudioMetricsSink execution 层）
    public static let eventHit = "kv.hit"
    public static let eventMiss = "kv.miss"

    // MARK: 缓存键（⛔ 必含模型 ID——跨模型共享语义不成立）

    /// SHA256 hex（CryptoKit 系统框架，零新增依赖）
    public static func sha256Hex(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// 缓存键 = SHA256(modelID + 分隔符 + prefixText)。分隔符 \u{1F}（unit
    /// separator）防「模型名尾 + 文本头」拼合撞键（a|bc ≠ ab|c）。
    public static func cacheKey(modelID: String, prefixText: String) -> String {
        sha256Hex(modelID + "\u{1F}" + prefixText)
    }

    /// 埋点 attrs 用：键前 8 位（碰撞可忽略，只作归组辨识）
    public static func prefixHash8(ofKey key: String) -> String {
        String(key.prefix(8))
    }

    // MARK: 命中判定（token 序列公共前缀）

    /// 两 token 序列的公共前缀长度（逐位比对，O(min(n,m))）
    public static func commonPrefixCount(_ a: [Int], _ b: [Int]) -> Int {
        let n = min(a.count, b.count)
        var i = 0
        while i < n, a[i] == b[i] { i += 1 }
        return i
    }

    /// 复用决策
    public enum Decision: Equatable, Sendable {
        /// 全新 prefill（reason 进埋点 attrs）
        case fresh(reason: String)
        /// 复用：cache 裁到 trimTo 个 token，增量 prefill 后缀 suffixCount 个
        case reuse(trimTo: Int, suffixCount: Int)
    }

    /// 判定：缓存 token 序列 vs 新 prompt token 序列。
    ///   · 无缓存 → fresh("no-cache")
    ///   · 公共前缀 < minReuse → fresh("prefix-too-short")
    ///   · 新 prompt 完全是缓存前缀（等长全同）→ 复用 count-1（末 token 重喂，
    ///     保持「cache=前 n-1、suffix=末 token」的生成入口不变式）
    ///   · 其余 → reuse(trimTo: 公共前缀长, suffixCount: 新序列余量)
    public static func decide(cachedTokens: [Int], newTokens: [Int],
                              minReuse: Int = minReuseTokens) -> Decision {
        guard !cachedTokens.isEmpty else { return .fresh(reason: "no-cache") }
        guard !newTokens.isEmpty else { return .fresh(reason: "empty-prompt") }
        var n = commonPrefixCount(cachedTokens, newTokens)
        n = min(n, newTokens.count - 1)   // 至少留 1 个新 token 作生成入口
        guard n >= max(1, minReuse) else { return .fresh(reason: "prefix-too-short") }
        return .reuse(trimTo: n, suffixCount: newTokens.count - n)
    }

    // MARK: TTL（容量=单槽，见文件头）

    public static func isExpired(cachedAt: Date, now: Date,
                                 ttl: Double = defaultTTLSeconds) -> Bool {
        now.timeIntervalSince(cachedAt) > ttl
    }
}
