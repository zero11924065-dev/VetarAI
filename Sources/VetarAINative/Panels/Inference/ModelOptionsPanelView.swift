//
//  ModelOptionsPanelView.swift
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

//  「模型选项」独立面板：ModelOptionsEditor 的独立宿主（现状应用里该编辑器
//  嵌在推理面板内；原生注册表给它单独导航位，故本面板负责自拉配置/后端态
//  并承载同一编辑器组件，编辑语义与推理面板内完全一致）。
//

import SwiftUI
import Combine

@MainActor
final class ModelOptionsPanelViewModel: ObservableObject {
    @Published private(set) var loaded = false
    let editor: ModelOptionsEditorViewModel

    private let appState: AppState
    private let clientOverride: (any InferencePanelClient)?
    private var client: (any InferencePanelClient)? {
        clientOverride ?? (appState.runtime.client as? any InferencePanelClient)
    }
    private var cfg: [String: Any] = [:]

    init(appState: AppState, clientOverride: (any InferencePanelClient)? = nil) {
        self.appState = appState
        self.clientOverride = clientOverride
        self.editor = ModelOptionsEditorViewModel()
        self.editor.onSaveBridge = { [weak self] patch in
            await self?.save(patch)
        }
    }

    func load() async {
        guard let client else { return }
        if let c = try? await client.fetchConfig() {
            cfg = c
        }
        let backend = (cfg["inference_backend"] as? String) ?? "ollama"
        editor.update(cfg: cfg,
                      isOllama: backend == "ollama",
                      isModelPackage: backend == "model_package",
                      busy: false)
        loaded = true
    }

    /// 编辑器 onSave = 补丁 PUT（与推理面板 saveBackend 同口径，后端合并语义）。
    private func save(_ patch: [String: Any]) async {
        guard let client else { return }
        editor.busy = true
        do {
            try await client.putConfig(patch)
            await load()
        } catch {
            appState.logger.warn("模型选项保存失败：\(SidecarError.describe(error))")
        }
        editor.busy = false
    }
}

public struct ModelOptionsPanelView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var vmBox = ModelOptionsPanelViewModelBox()

    public init() {}

    public var body: some View {
        if let vm = vmBox.vm {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 8) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 14))
                            .foregroundStyle(VTheme.textPrimary)
                        Text("模型推理参数（按模型单独配置）")
                            .font(VTheme.Typo.sectionTitle)
                            .foregroundStyle(VTheme.textPrimary)
                    }
                    if vm.loaded {
                        ModelOptionsEditorView(vm: vm.editor)
                    } else {
                        VLoadingView("加载配置…")
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(VTheme.bgApp)
            .task { await vm.load() }
        } else {
            VLoadingView("模型选项初始化…")
                .task { vmBox.attach(appState: appState) }
        }
    }
}

/// 延迟构建（需要已注入的 AppState）。
@MainActor
final class ModelOptionsPanelViewModelBox: ObservableObject {
    @Published var vm: ModelOptionsPanelViewModel?
    func attach(appState: AppState) {
        if vm == nil { vm = ModelOptionsPanelViewModel(appState: appState) }
    }
}
