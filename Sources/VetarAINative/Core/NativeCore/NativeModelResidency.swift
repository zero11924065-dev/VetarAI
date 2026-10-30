//
//  NativeModelResidency.swift
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

//  单一策略源：按模型精确匹配常驻配置；只对 Ollama 对话请求注入
//  keep_alive=-1。未勾选时不增删请求键，尊重 Ollama 服务端现有策略；
//  不读写 OLLAMA_KEEP_ALIVE 全局环境变量。
//
//  内存建议为纯函数：以模型列表 size 真值作权重体积估算依据，nil/0 均
//  视为未知。预算取物理内存 25%，为系统、KV 缓存与运行时预留余量；建议
//  数量按已知体积升序贪心求最大个数。预算只提醒，不限制用户选择。
//

import Foundation
import Darwin

public struct NativeMemorySnapshot: Equatable, Sendable {
    /// 物理内存字节数（hw.memsize，失败时回退 ProcessInfo）。
    public let totalBytes: Int64
    /// Mach VM free pages 字节数；不含 inactive/cache，读取失败为 nil。
    public let freeBytes: Int64?

    public init(totalBytes: Int64, freeBytes: Int64?) {
        self.totalBytes = totalBytes
        self.freeBytes = freeBytes
    }
}

public struct NativeResidencyAdvice: Equatable, Sendable {
    public let budgetBytes: Int64
    public let recommendedCount: Int
    public let selectedKnownBytes: Int64
    public let unknownCandidateCount: Int
    public let unknownSelectedCount: Int
    public let exceedsBudget: Bool

    public init(budgetBytes: Int64, recommendedCount: Int, selectedKnownBytes: Int64,
                unknownCandidateCount: Int, unknownSelectedCount: Int, exceedsBudget: Bool) {
        self.budgetBytes = budgetBytes
        self.recommendedCount = recommendedCount
        self.selectedKnownBytes = selectedKnownBytes
        self.unknownCandidateCount = unknownCandidateCount
        self.unknownSelectedCount = unknownSelectedCount
        self.exceedsBudget = exceedsBudget
    }
}

public enum NativeModelResidency {
    public static let configKey = "model_residency"
    /// 常驻权重预算 = 物理内存 / 4（25%）。这是保守建议，不是硬性上限。
    public static let memoryBudgetDivisor: Int64 = 4
    /// 无名参标记时，以 >=16 GiB 的模型文件提示“大体积”，不断言参数规模。
    public static let largeModelWarningBytes: Int64 = 16 * 1_024 * 1_024 * 1_024

    /// 缺键、null 或磁盘手改成的非法类型都安全回落为空集；写入侧由 store 校验。
    public static func residentModels(_ config: [String: JSONValue]) -> Set<String> {
        Set(config[configKey]?.stringArray ?? [])
    }

    /// 模型名精确匹配：qwen3 不会误命中 qwen3:latest。
    public static func isResident(model: String, config: [String: JSONValue]) -> Bool {
        residentModels(config).contains(model)
    }

    /// 勾选才覆盖请求级 keep_alive=-1；未勾选完整保留原 payload。
    public static func applyingOllamaKeepAlive(
        _ payload: [String: JSONValue], model: String, config: [String: JSONValue]
    ) -> [String: JSONValue] {
        guard isResident(model: model, config: config) else { return payload }
        var result = payload
        result["keep_alive"] = .int(-1)
        return result
    }

    /// 工作流/委派收尾等自动释放的豁免；显式请求体本身不受此函数影响。
    public static func shouldAutomaticallyUnloadOllama(
        model: String, config: [String: JSONValue]
    ) -> Bool {
        !isResident(model: model, config: config)
    }

    /// 切到模型包前，只卸载未勾选的 Ollama 驻留模型，保持原名单顺序。
    public static func ollamaAutomaticUnloadCandidates(
        loaded: [String], config: [String: JSONValue]
    ) -> [String] {
        let resident = residentModels(config)
        return loaded.filter { !resident.contains($0) }
    }

    /// 只读系统内存，不发起模型状态请求，也不把缓存冒充为空闲内存。
    public static func currentMemorySnapshot() -> NativeMemorySnapshot {
        var rawTotal: UInt64 = 0
        var totalSize = MemoryLayout<UInt64>.size
        let sysctlOK = sysctlbyname("hw.memsize", &rawTotal, &totalSize, nil, 0)
        let physical = sysctlOK == 0 && rawTotal > 0
            ? rawTotal : ProcessInfo.processInfo.physicalMemory
        return NativeMemorySnapshot(
            totalBytes: Int64(clamping: physical),
            freeBytes: machVMFreeBytes())
    }

    private static func machVMFreeBytes() -> Int64? {
        let host = mach_host_self()
        var pageSize: vm_size_t = 0
        guard host_page_size(host, &pageSize) == KERN_SUCCESS, pageSize > 0 else { return nil }
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPointer in
                host_statistics64(host, HOST_VM_INFO64, intPointer, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let (bytes, overflow) = UInt64(stats.free_count).multipliedReportingOverflow(
            by: UInt64(pageSize))
        return Int64(clamping: overflow ? UInt64.max : bytes)
    }

    /// 以 size>0 为唯一已知体积；同名重复项取最大已知值，避免重复计数。
    /// 建议数量是“最多能放下几个”，因此按体积升序贪心；已选合计不做上限截断。
    public static func advice(
        models: [InferenceModelEntry], selected: Set<String>, totalMemory: Int64
    ) -> NativeResidencyAdvice {
        let budget = max(totalMemory, 0) / memoryBudgetDivisor
        var names = Set<String>()
        var knownSizes: [String: Int64] = [:]
        for model in models {
            names.insert(model.name)
            if let size = model.size, size > 0 {
                knownSizes[model.name] = max(knownSizes[model.name] ?? 0, size)
            }
        }

        var used: Int64 = 0
        var recommended = 0
        for size in knownSizes.values.sorted() {
            // used<=budget，差值比较避免 Int64 加法溢出。
            guard size <= budget - used else { break }
            used += size
            recommended += 1
        }

        var selectedKnown: Int64 = 0
        for name in selected {
            guard let size = knownSizes[name] else { continue }
            let (sum, overflow) = selectedKnown.addingReportingOverflow(size)
            selectedKnown = overflow ? Int64.max : sum
        }
        let unknownCandidates = names.filter { knownSizes[$0] == nil }.count
        let unknownSelected = selected.filter { knownSizes[$0] == nil }.count
        return NativeResidencyAdvice(
            budgetBytes: budget,
            recommendedCount: recommended,
            selectedKnownBytes: selectedKnown,
            unknownCandidateCount: unknownCandidates,
            unknownSelectedCount: unknownSelected,
            exceedsBudget: selectedKnown > budget)
    }

    /// 27B/35B 名参标记或大体积文件只触发提醒，绝不参与选择门禁。
    public static func needsLargeModelWarning(name: String, size: Int64?) -> Bool {
        if let size, size >= largeModelWarningBytes { return true }
        let pattern = #"(?i)(?:^|[^0-9])(?:27|35)\s*b(?:[^0-9a-z]|$)"#
        return name.range(of: pattern, options: .regularExpression) != nil
    }
}
