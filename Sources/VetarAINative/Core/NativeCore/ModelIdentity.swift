//
//  ModelIdentity.swift
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

//  背景：ollama 惯例——不带 tag 的模型名等价于 ":latest"。用户存的默认模型
//  「qwen3.8」在可用列表「qwen3.8:latest」面前，精确字符串匹配会误判
//  「当前不可用」（设置页三处）甚至被静默替换（会话引导一处）。
//  NativeDelegation.swift（model_override 存在性校验）曾有同款内联兜底；
//  本文件把判定口径收编为统一纯函数，供各 UI/引导层调用。
//
//  口径（与 ollama model.ParseName 对齐）：
//    · 仅当最后一个 ":" 出现在最后一个 "/" 之后，它才是 tag 分隔符；
//      否则（注册表端口 "hf.co:8080/x/y"）":" 属于主机名，不算 tag。
//    · 名中无 tag 段 → 视为 ":latest"（"qwen3.8" ≡ "qwen3.8:latest"）。
//    · tag 分隔但 base/tag 有一侧为空（"qwen3:" / ":8b"）→ 畸形，
//      整体按无 tag 处理（两侧对称，比较结果仍自洽）。
//    · 大小写：精确匹配不折叠——与全仓现存口径一致（ollama 返回名
//      原样入列、配置原样存储；NativeDelegation 校验同为精确比较）。
//
//  ⚠️ 与 NativeDelegation model_override 校验的口径差异（有意保留）：
//    该处除精确/tag 兜底外还有「同 base 任意 tag 命中并重写为列表名」
//    的宽松分支（"qwen3-vl:8b" 可命中 "qwen3-vl:13b"），属委派自选的
//    容错语义，行为不得变，故不收编；本枚举是严格口径（tag 不同即不同模型）。
//

import Foundation

public enum ModelIdentity {

    /// 归一化：返回「显式带 tag」的规范形（无 tag 段补 ":latest"）。
    /// 纯展示/比较用，不回写任何配置。
    public static func canonical(_ name: String) -> String {
        guard let colon = name.lastIndex(of: ":") else { return name + ":latest" }
        // ":" 在最后一个 "/" 之前 → 注册表主机端口，不是 tag
        if let slash = name.lastIndex(of: "/"), slash > colon { return name + ":latest" }
        let base = name[..<colon]
        let tag = name[name.index(after: colon)...]
        // 畸形（base 或 tag 为空）→ 整体按无 tag 名处理
        guard !base.isEmpty, !tag.isEmpty else { return name + ":latest" }
        return name   // 已显式带 tag，原样即规范形
    }

    /// 两个模型名是否指向同一模型（":latest" 互认；tag 不同即不同）。
    public static func sameModel(_ a: String, _ b: String) -> Bool {
        a == b || canonical(a) == canonical(b)
    }

    /// 模型是否在可用列表中（归一化口径；列表为空 → false，交调用方分支文案）。
    public static func isAvailable(_ model: String, in available: [String]) -> Bool {
        available.contains { sameModel($0, model) }
    }
}
