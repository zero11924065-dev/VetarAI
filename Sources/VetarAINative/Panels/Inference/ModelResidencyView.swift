//
//  ModelResidencyView.swift
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

//  独立嵌入 InferencePanelBody；不拥有 AppState，不改 InferencePanelView(Model)。
//  直接复用 runtime.kernel.config，保存成功后才更新勾选状态，避免 UI 与磁盘漂移。
//  Ollama 使用请求级 keep_alive=-1；llama.cpp / MLX 保留既有调用后驻留与
//  单槽换装行为；OpenAI 兼容端由服务端管理。未勾选不会主动卸载模型。
//

import SwiftUI

@MainActor
final class ModelResidencyViewModel: ObservableObject {
    @Published private(set) var config: [String: JSONValue]
    @Published private(set) var selected: Set<String>
    @Published private(set) var models: [InferenceModelEntry]
    @Published private(set) var memory: NativeMemorySnapshot
    @Published private(set) var errorMessage: String?

    private let store: NativeConfigStore
    private let memoryProbe: () -> NativeMemorySnapshot
    private var backendOverride: String?

    var backend: String {
        backendOverride ?? config["inference_backend"]?.string ?? "ollama"
    }
    var isOllama: Bool { backend == "ollama" }

    init(config store: NativeConfigStore, models: [InferenceModelEntry],
         backend: String? = nil,
         memoryProbe: @escaping () -> NativeMemorySnapshot = NativeModelResidency.currentMemorySnapshot) {
        var initial = NativeConfigStore.defaultConfig
        var initialError: String?
        do {
            initial = try store.getConfig()
        } catch {
            initialError = "读取常驻配置失败：\(error.localizedDescription)"
        }
        self.store = store
        self.config = initial
        self.selected = NativeModelResidency.residentModels(initial)
        self.models = Self.deduplicated(models)
        self.memory = memoryProbe()
        self.errorMessage = initialError
        self.memoryProbe = memoryProbe
        self.backendOverride = backend
    }

    static func deduplicated(_ models: [InferenceModelEntry]) -> [InferenceModelEntry] {
        var seen = Set<String>()
        return models.filter { seen.insert($0.name).inserted }
    }

    func reload(models: [InferenceModelEntry], backend: String?) {
        self.models = Self.deduplicated(models)
        self.backendOverride = backend
        do {
            let latest = try store.getConfig()
            config = latest
            selected = NativeModelResidency.residentModels(latest)
            errorMessage = nil
        } catch {
            errorMessage = "读取常驻配置失败：\(error.localizedDescription)"
        }
    }

    func refreshMemory() {
        memory = memoryProbe()
    }

    func setResident(_ resident: Bool, model: String) {
        guard resident != selected.contains(model) else { return }
        var next = selected
        if resident { next.insert(model) } else { next.remove(model) }
        do {
            // 非乐观更新：reloadConfig 校验并原子落盘成功后，才改变可见勾选。
            let saved = try store.reloadConfig(patch: [
                NativeModelResidency.configKey: .array(next.sorted().map { .string($0) }),
            ])
            config = saved
            selected = NativeModelResidency.residentModels(saved)
            errorMessage = nil
        } catch {
            errorMessage = "保存常驻配置失败：\(error.localizedDescription)。勾选状态未改变。"
        }
    }
}

private struct ModelResidencyDisplayModel: Identifiable {
    let model: InferenceModelEntry
    let missing: Bool
    var id: String { model.name }
}

public struct ModelResidencyView: View {
    @StateObject private var vm: ModelResidencyViewModel
    private let models: [InferenceModelEntry]
    private let backend: String?

    /// - Parameters:
    ///   - config: 必须传 runtime.kernel.config，确保与请求连接器的写读同源。
    ///   - models: 统一模型列表（Ollama + 模型包 + .vmodel）。
    ///   - backend: 传 vm.backend，后端切换时即时更新可用性说明。
    public init(config: NativeConfigStore, models: [InferenceModelEntry],
                backend: String? = nil) {
        self.models = models
        self.backend = backend
        _vm = StateObject(wrappedValue: ModelResidencyViewModel(
            config: config, models: models, backend: backend))
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: VTheme.Space.s3) {
            HStack(alignment: .top, spacing: VTheme.Space.s3) {
                VStack(alignment: .leading, spacing: VTheme.Space.s1) {
                    Text("模型常驻")
                        .font(VTheme.Typo.sectionTitle)
                        .foregroundStyle(VTheme.textPrimary)
                    Text("手动勾选需要免去二次对话冷加载的模型；默认全部不勾选。")
                        .font(VTheme.Typo.caption)
                        .foregroundStyle(VTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: VTheme.Space.s2)
                Button {
                    vm.refreshMemory()
                } label: {
                    Label("刷新内存", systemImage: "arrow.clockwise")
                        .font(VTheme.Typo.caption)
                }
                .buttonStyle(.borderless)
                .help("重新读取系统物理内存与 Mach VM 空闲页")
                .accessibilityIdentifier("inference.residency.refreshMemory")
            }

            if let error = vm.errorMessage {
                VCallout(.error, error)
                    .accessibilityIdentifier("inference.residency.error")
            }
            if !vm.isOllama {
                VCallout(.info, vm.backend == "openai_compatible"
                    ? "OpenAI 兼容后端的模型驻留由服务端管理；此处不注入 Ollama 参数。已保存的 Ollama 常驻选择会保留，可取消。"
                    : "请求级常驻勾选仅适用于 Ollama；模型包与 .vmodel 沿用现有引擎驻留规则。")
            }

            memoryCard
            selectionSummary

            if displayedModels.isEmpty {
                Text("暂无可显示的模型。模型出现在统一列表后，即可在此设置常驻。")
                    .font(VTheme.Typo.caption)
                    .foregroundStyle(VTheme.textTertiary)
                    .padding(.vertical, VTheme.Space.s2)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(displayedModels) { row in
                        modelRow(row)
                        if row.id != displayedModels.last?.id {
                            Divider().overlay(VTheme.borderSubtle)
                        }
                    }
                }
                .background(VTheme.bgCard, in: RoundedRectangle(cornerRadius: VTheme.Radius.s))
            }

            VStack(alignment: .leading, spacing: VTheme.Space.s1) {
                Text("勾选仅影响 VetarAI 后续 Ollama 请求：注入 keep_alive=-1；未勾选请求不带该键。不会修改 Ollama 全局 OLLAMA_KEEP_ALIVE，取消勾选也不会主动卸载。")
                Text("模型体积是内存估算依据，不含 KV 缓存、上下文和运行时开销。llama.cpp／MLX 模型包调用后由现有引擎驻留，同一引擎仍为单槽，换装会释放旧模型。")
                Text("常驻小模型也可同时选作投机草稿；此处不新增投机配置。")
            }
            .font(VTheme.Typo.micro)
            .foregroundStyle(VTheme.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, VTheme.Space.s5)
        .padding(.vertical, VTheme.Space.s4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(VTheme.bgCard, in: RoundedRectangle(cornerRadius: VTheme.Radius.l))
        .overlay(RoundedRectangle(cornerRadius: VTheme.Radius.l).stroke(VTheme.borderSubtle))
        .onAppear {
            vm.reload(models: models, backend: backend)
            vm.refreshMemory()
        }
        .onChange(of: models) { _, newModels in
            vm.reload(models: newModels, backend: backend)
        }
        .onChange(of: backend) { _, newBackend in
            vm.reload(models: models, backend: newBackend)
        }
    }

    private var displayedModels: [ModelResidencyDisplayModel] {
        var rows = vm.models.map { ModelResidencyDisplayModel(model: $0, missing: false) }
        let present = Set(vm.models.map(\.name))
        for name in vm.selected.sorted() where !present.contains(name) {
            rows.append(ModelResidencyDisplayModel(
                model: InferenceModelEntry(name: name, size: nil, source: nil), missing: true))
        }
        return rows
    }

    private var ollamaCandidates: [InferenceModelEntry] {
        guard vm.isOllama else { return [] }
        return vm.models.filter { !isEngineManaged($0) }
    }

    private var advice: NativeResidencyAdvice {
        NativeModelResidency.advice(
            models: ollamaCandidates, selected: vm.selected, totalMemory: vm.memory.totalBytes)
    }

    private var memoryCard: some View {
        VStack(alignment: .leading, spacing: VTheme.Space.s2) {
            HStack(alignment: .top, spacing: VTheme.Space.s4) {
                metric(title: "物理内存", value: Self.formatSize(vm.memory.totalBytes))
                    .frame(maxWidth: .infinity, alignment: .leading)
                metric(title: "VM 空闲", value: Self.formatOptionalSize(vm.memory.freeBytes))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("VM 空闲仅统计 Mach free pages，不含缓存或可回收页，因此是保守口径。")
                .font(VTheme.Typo.micro)
                .foregroundStyle(VTheme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(VTheme.Space.s3)
        .background(VTheme.bgHover, in: RoundedRectangle(cornerRadius: VTheme.Radius.s))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("inference.residency.memory")
    }

    @ViewBuilder
    private var selectionSummary: some View {
        if vm.isOllama {
            VStack(alignment: .leading, spacing: VTheme.Space.s1) {
                Text("建议预算为物理内存的 25%（\(Self.formatSize(advice.budgetBytes))）；按已知体积从小到大估算，最多可常驻 \(advice.recommendedCount) 个。")
                    .font(VTheme.Typo.caption)
                    .foregroundStyle(VTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if advice.unknownCandidateCount > 0 {
                    Text("\(advice.unknownCandidateCount) 个模型体积未知，未计入可常驻数建议。")
                        .font(VTheme.Typo.micro)
                        .foregroundStyle(VTheme.textTertiary)
                }
                if !vm.selected.isEmpty {
                    Text("已选 \(vm.selected.count) 个 · 已知体积合计 \(Self.formatSize(advice.selectedKnownBytes))")
                        .font(VTheme.Typo.caption)
                        .foregroundStyle(VTheme.textPrimary)
                        .accessibilityIdentifier("inference.residency.selection")
                }
                if advice.unknownSelectedCount > 0 {
                    Text("\(advice.unknownSelectedCount) 个已选项体积未知，未计入上述合计。")
                        .font(VTheme.Typo.micro)
                        .foregroundStyle(VTheme.warnText)
                }
            }
            if advice.exceedsBudget {
                VCallout(.warn, "已选模型的已知体积合计超过 25% 建议预算。仍可保存，但可能挤压系统、KV 缓存与其他模型；请结合当前内存谨慎选择。")
                    .accessibilityIdentifier("inference.residency.overBudget")
            }
            if hasLargeSelectedModel {
                VCallout(.warn, "已选包含 27B／35B 级或大体积模型。这里只提醒、不禁止；内存充裕时可自行决定，默认配置仍为空。")
                    .accessibilityIdentifier("inference.residency.largeModel")
            }
        }
    }

    private var hasLargeSelectedModel: Bool {
        displayedModels.contains { row in
            vm.selected.contains(row.id)
                && NativeModelResidency.needsLargeModelWarning(
                    name: row.model.name, size: row.model.size)
        }
    }

    private func metric(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: VTheme.Space.s1) {
            Text(title)
                .font(VTheme.Typo.micro)
                .foregroundStyle(VTheme.textTertiary)
            Text(value)
                .font(VTheme.Typo.body)
                .foregroundStyle(VTheme.textPrimary)
        }
        .accessibilityElement(children: .combine)
    }

    private func modelRow(_ row: ModelResidencyDisplayModel) -> some View {
        let managed = isEngineManaged(row.model)
        let selected = vm.selected.contains(row.id)
        let canTurnOn = vm.isOllama && !managed && !row.missing
        return HStack(alignment: .top, spacing: VTheme.Space.s3) {
            if !managed {
                Toggle(isOn: Binding(
                    get: { selected },
                    set: { vm.setResident($0, model: row.id) }
                )) {
                    modelLabel(row)
                }
                .toggleStyle(.checkbox)
                .disabled(!canTurnOn && !selected)
                .accessibilityLabel("\(row.model.name) 模型常驻")
                .accessibilityHint("勾选后，VetarAI 后续 Ollama 请求会注入 keep_alive 为 -1；取消不会主动卸载。")
                .accessibilityIdentifier("inference.residency.toggle.\(row.model.name)")
            } else {
                modelLabel(row)
            }
            Spacer(minLength: VTheme.Space.s2)
            VStack(alignment: .trailing, spacing: VTheme.Space.s1) {
                Text("模型体积")
                    .font(VTheme.Typo.micro)
                    .foregroundStyle(VTheme.textTertiary)
                Text(Self.formatOptionalSize(row.model.size))
                    .font(VTheme.Typo.mono)
                    .foregroundStyle(VTheme.textSecondary)
            }
        }
        .padding(.vertical, VTheme.Space.s3)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("inference.residency.row.\(row.model.name)")
    }

    private func modelLabel(_ row: ModelResidencyDisplayModel) -> some View {
        let large = NativeModelResidency.needsLargeModelWarning(
            name: row.model.name, size: row.model.size)
        return VStack(alignment: .leading, spacing: VTheme.Space.s1) {
            Text(row.model.name)
                .font(VTheme.Typo.mono)
                .foregroundStyle(VTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text(detail(for: row, large: large))
                .font(VTheme.Typo.micro)
                .foregroundStyle(large ? VTheme.warnText : VTheme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func detail(for row: ModelResidencyDisplayModel, large: Bool) -> String {
        if row.missing { return "当前模型列表未显示 · 可取消常驻" }
        if isEngineManaged(row.model) {
            return row.model.isModelPack
                ? "模型包 · 调用后由 llama.cpp／MLX 驻留 · 单槽换装"
                : ".vmodel · 调用后由现有 MLX 引擎驻留 · 单槽换装"
        }
        if vm.backend == "openai_compatible" { return "OpenAI 兼容端 · 由服务端管理" }
        if !vm.isOllama { return "切换到 Ollama 后可设置请求级常驻" }
        return large ? "27B／35B 级或大体积 · 只提醒，不禁止" : "Ollama · 请求级常驻"
    }

    private func isEngineManaged(_ model: InferenceModelEntry) -> Bool {
        model.isModelPack || model.source == "vmodel"
    }

    private static func formatOptionalSize(_ size: Int64?) -> String {
        guard let size, size > 0 else { return "未知" }
        return ModelPackFormat.formatSize(size)
    }

    private static func formatSize(_ size: Int64) -> String {
        size > 0 ? ModelPackFormat.formatSize(size) : "未知"
    }
}
