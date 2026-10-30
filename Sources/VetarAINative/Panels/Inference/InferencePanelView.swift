//
//  InferencePanelView.swift
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

//  推理后端面板（SwiftUI 移植，对标 InferencePanel.tsx，463 行）：
//    · 标题 + 状态区卡（在线圆点 / 测试连接 / 离线明细 / 操作反馈消息条）
//    · 后端选择区卡（Ollama / OpenAI 兼容单选卡 + 旧 model_package 配置兼容提示）
//    · 推理参数与超时区卡（超时三键 + 懒加载设置 + 每模型参数编辑器）
//    · 模型列表区卡（统一列表 + 设为默认 + 参数 + 拉取/删除）
//  文案逐字对齐现状实现；视觉用 VTheme 近似（接入指南 §3）。
//

import SwiftUI

public struct InferencePanelView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var vmBox = InferencePanelViewModelBox()

    public init() {}

    public var body: some View {
        // 与 ChatPanelView 同一 Box 模式：StateObject 构建早于 environmentObject 注入
        if let vm = vmBox.vm {
            InferencePanelBody(vm: vm, runtime: appState.runtime)
        } else {
            VLoadingView("推理面板初始化…")
                .task { vmBox.attach(appState: appState) }
        }
    }
}

/// 延迟构建 InferencePanelViewModel（需要已注入的 AppState）。
@MainActor
final class InferencePanelViewModelBox: ObservableObject {
    @Published var vm: InferencePanelViewModel?
    func attach(appState: AppState) {
        if vm == nil { vm = InferencePanelViewModel(appState: appState) }
    }
}

private struct InferencePanelBody: View {
    @ObservedObject var vm: InferencePanelViewModel
    /// 直接观察 NativeRuntime（AppState 不转发子服务的 objectWillChange——
    /// 面板必须自己观察侧车才能在「就绪」时自愈重载，W2 收口冒烟实测）。
    @ObservedObject var runtime: NativeRuntime
    /// 新增环境变量输入草稿（变量名 / 值）。
    @State private var newEnvKey = ""
    @State private var newEnvValue = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                titleRow
                statusCard
                backendCard
                // A1 小模型常驻区卡（勾选+内存感知；Ollama 请求级 keep_alive，不改服务端全局设置）
                ModelResidencyView(config: runtime.kernel.config, models: vm.models, backend: vm.backend)
                accelCard
                envVarsCard
                paramsCard
                modelsCard
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(VTheme.bgApp)
        .onAppear { vm.start() }
        .onDisappear { vm.stop() }
        // 侧车就绪竞态自愈：面板先于侧车打开时 start() 早退，就绪后补载一次。
        // P3-W6⑤：nativeReady 于 runtime init 同步点亮、任何视图出现前恒 true，
        // 旧「就绪自愈」onChange（永不触发）随侧车归零删除——首拉在挂载链路上。
    }

    // MARK: - 标题

    private var titleRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "cpu")
                .font(.system(size: 14))
                .foregroundStyle(VTheme.textPrimary)
            Text("推理后端")
                // 方向2 波次2：设置壳页标题统一 Typo.pageTitle（原版 :75-77
                // sectionTitle 14 升档；本文件仅动此一行）
                .font(VTheme.Typo.pageTitle)
                .foregroundStyle(VTheme.textPrimary)
        }
    }

    // MARK: - 状态区卡

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Circle()
                    .fill(status != nil
                          ? (status!.online ? VTheme.ok : VTheme.danger)
                          : VTheme.borderStrong)
                    .frame(width: 10, height: 10)
                    .accessibilityIdentifier("inference.statusDot")
                Text(backendTitle + (status != nil ? (status!.online ? " · 在线" : " · 离线") : ""))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(VTheme.textPrimary)
                    .accessibilityIdentifier("inference.statusTitle")
                Button {
                    Task { await vm.testConnection() }
                } label: {
                    HStack(spacing: 4) {
                        if vm.busy { ProgressView().controlSize(.mini) }
                        Text(vm.busy ? "检测中…" : "测试连接")
                            .font(VTheme.Typo.caption)
                    }
                }
                .buttonStyle(.vSecondary)
                .controlSize(.small)
                .disabled(vm.busy)
                .accessibilityIdentifier("inference.testConnection")
            }
            if let st = status, !st.online, !st.detail.isEmpty {
                VCallout(.error, st.detail)
            }
            if let msg = vm.message {
                VCallout(vm.messageKind.calloutKind, msg)
                    .accessibilityIdentifier("inference.message")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(VTheme.bgCard, in: RoundedRectangle(cornerRadius: VTheme.Radius.l))
        .overlay(RoundedRectangle(cornerRadius: VTheme.Radius.l).stroke(VTheme.borderSubtle))
    }

    private var status: InferenceStatusInfo? { vm.status }

    private var backendTitle: String {
        vm.isOllama ? "Ollama" : vm.isModelPackage ? "模型包" : "OpenAI 兼容后端"
    }

    // 方向2 波次2：原 messageKind 字符串匹配（含「失败」=error、含「正在」=info，
    // 其余=success）已废——ViewModel 直接产出 PanelMessageKind 枚举（vm.messageKind），
    // 映射见文件尾 calloutKind；文案改字不再改变状态色。

    // MARK: - 后端选择区卡

    private var backendCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("后端选择")
                .font(VTheme.Typo.sectionTitle)
                .foregroundStyle(VTheme.textPrimary)

            HStack(spacing: 12) {
                backendRadioCard(
                    title: "Ollama", subtitle: "本地运行，自动管理模型",
                    selected: vm.isOllama
                ) {
                    Task { await vm.selectOllamaBackend() }
                }
                backendRadioCard(
                    title: "OpenAI 兼容", subtitle: "第三方 API 或本地中转",
                    selected: vm.backend == "openai_compatible"
                ) {
                    vm.markOpenAICompatibleSelected()
                }
            }

            // 旧版「模型包后端」配置兼容提示（0.4.30 W2，文案逐字）
            if vm.isModelPackage {
                VCallout(.info, "当前为旧版「模型包后端」配置。模型包现已与后端模型并行可用（按模型名自动路由，对话时自动换装），点击上方 Ollama 或 OpenAI 兼容即可切回常规配置；模型包仍在「模型包」面板安装与管理。")
            }

            if vm.isOllama {
                ollamaConfigForm
            } else if !vm.isModelPackage {
                openAIConfigForm
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(VTheme.bgCard, in: RoundedRectangle(cornerRadius: VTheme.Radius.l))
        .overlay(RoundedRectangle(cornerRadius: VTheme.Radius.l).stroke(VTheme.borderSubtle))
    }

    private func backendRadioCard(title: String, subtitle: String, selected: Bool,
                                  action: @escaping () -> Void) -> some View {
        // 方向2 波次2：hover 底色反馈需 @State 承载，抽为 BackendRadioCard struct（文件尾）
        BackendRadioCard(title: title, subtitle: subtitle, selected: selected, action: action)
    }

    private var ollamaConfigForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Ollama 地址")
                .font(VTheme.Typo.caption)
                .foregroundStyle(VTheme.textSecondary)
            HStack(spacing: 8) {
                TextField("http://localhost:11434", text: $vm.ollamaURLDraft)
                    .textFieldStyle(.plain)
                    .vInputStyle()
                    .accessibilityIdentifier("inference.ollamaURL")
                Button {
                    Task { await vm.saveOllamaURL() }
                } label: {
                    Text("保存").font(VTheme.Typo.caption)
                }
                .buttonStyle(.vPrimary)
                .controlSize(.small)
                .disabled(vm.busy)
                .accessibilityIdentifier("inference.saveOllamaURL")
            }
            Text("本机默认 http://localhost:11434；Ollama 运行在其他机器或自定义端口时，改为对应地址。")
                .font(VTheme.Typo.caption)
                .foregroundStyle(VTheme.textTertiary)
                .lineSpacing(2)
        }
        .padding(.leading, 4)
    }

    private var openAIConfigForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("适配 LM Studio、llama.cpp server、vLLM 等提供 OpenAI 兼容接口的启动器。LM Studio：先在应用内开启本地服务器（默认端口 1234），地址填 http://localhost:1234/v1，然后点\"保存并切换\"。")
                .font(VTheme.Typo.caption)
                .foregroundStyle(VTheme.textTertiary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            TextField("http://localhost:1234/v1", text: $vm.openAIBaseURLDraft)
                .textFieldStyle(.plain)
                .vInputStyle()
                .accessibilityIdentifier("inference.openAIBaseURL")
            SecureField("API Key（可选，远程中转才需要）", text: $vm.openAIKeyDraft)
                .textFieldStyle(.plain)
                .vInputStyle()
                .accessibilityIdentifier("inference.openAIKey")
            Toggle("该后端支持工具调用（不支持请取消勾选）", isOn: $vm.openAISupportsTools)
                .font(VTheme.Typo.body)
                .foregroundStyle(VTheme.textPrimary)
                .accessibilityIdentifier("inference.openAISupportsTools")
            HStack(spacing: 8) {
                Button {
                    Task { await vm.saveOpenAICompatible() }
                } label: {
                    HStack(spacing: 4) {
                        if vm.busy { ProgressView().controlSize(.mini) }
                        Text("保存并切换").font(VTheme.Typo.caption)
                    }
                }
                .buttonStyle(.vPrimary)
                .controlSize(.small)
                .disabled(vm.busy || vm.openAIBaseURLDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                .accessibilityIdentifier("inference.saveOpenAI")
                if vm.openAIBaseURLDraft.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text("请先填写地址")
                        .font(VTheme.Typo.caption)
                        .foregroundStyle(VTheme.textTertiary)
                }
            }
        }
        .padding(.leading, 4)
    }

    // MARK: - Ollama 加速优化区卡（检测 / 一键优化 / 恢复）

    @ViewBuilder
    private var accelCard: some View {
        if vm.isOllama {
            VStack(alignment: .leading, spacing: 12) {
                Text("Ollama 加速优化")
                    .font(VTheme.Typo.sectionTitle)
                    .foregroundStyle(VTheme.textPrimary)

                VStack(alignment: .leading, spacing: 6) {
                    Text("KV 缓存量化档位")
                        .font(VTheme.Typo.caption)
                        .foregroundStyle(VTheme.textSecondary)
                    Picker("KV 缓存量化档位", selection: $vm.selectedKVCacheTier) {
                        ForEach(NativeOllamaKVCacheTier.allCases, id: \.rawValue) { tier in
                            Text(tier.pickerLabel)
                                .tag(tier)
                                .accessibilityIdentifier("inference.kvCacheTier.\(tier.rawValue)")
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .disabled(vm.accelCurrentKVCacheType != nil && vm.accelCurrentKVCacheTier == nil)
                    .accessibilityIdentifier("inference.kvCacheTier")
                    Text(vm.selectedKVCacheTier.detail)
                        .font(VTheme.Typo.caption)
                        .foregroundStyle(VTheme.textTertiary)
                    Text("当前配置：\(vm.accelCurrentKVCacheType ?? "未设置（默认推荐 q8_0）")")
                        .font(VTheme.Typo.micro)
                        .foregroundStyle(VTheme.textTertiary)
                        .accessibilityIdentifier("inference.kvCacheCurrent")
                }

                Text("q8_0 / q4_0 需配合 Flash Attention；Flash Attention 关闭时量化不生效或可能不稳定。f16 为不量化。")
                    .font(VTheme.Typo.caption)
                    .foregroundStyle(VTheme.textSecondary)
                    .lineSpacing(2)
                    .accessibilityIdentifier("inference.kvCacheFADependency")

                if vm.accelPendingOperations.isEmpty {
                    if vm.accelCurrentKVCacheType != nil && vm.accelCurrentKVCacheTier == nil {
                        Text("检测到自定义 KV 缓存值；默认流程不会覆盖，可在下方环境变量编辑器中调整。")
                            .font(VTheme.Typo.caption)
                            .foregroundStyle(VTheme.textTertiary)
                    } else {
                        Text("已配置全部可引导优化项；选择不同 KV 档位后可明确换档。")
                            .font(VTheme.Typo.caption)
                            .foregroundStyle(VTheme.textTertiary)
                    }
                } else {
                    Text("检测到 \(vm.accelPendingOperations.count) 项可调整的服务端设置（授权后执行，可随时恢复）：")
                        .font(VTheme.Typo.caption)
                        .foregroundStyle(VTheme.textSecondary)
                    ForEach(vm.accelPendingOperations, id: \.rawValue) { opt in
                        Text(opt == .kvCacheType
                             ? "• KV 缓存档位 \(vm.selectedKVCacheTier.pickerLabel)"
                             : "• \(opt.label)")
                            .font(VTheme.Typo.caption)
                            .foregroundStyle(VTheme.textSecondary)
                    }
                    Button {
                        Task { await vm.applyAccel() }
                    } label: {
                        Text("应用优化并重启 Ollama").font(VTheme.Typo.caption)
                    }
                    .buttonStyle(.vPrimary)
                    .controlSize(.small)
                    .accessibilityIdentifier("inference.accelApply")
                }

                Button { vm.restoreAccel() } label: {
                    Text("恢复默认并重启").font(VTheme.Typo.caption)
                }
                .buttonStyle(.vSecondary)
                .controlSize(.small)
                .accessibilityIdentifier("inference.accelRestore")

                if let msg = vm.accelMessage {
                    Text(msg).font(VTheme.Typo.caption).foregroundStyle(VTheme.textSecondary)
                }
                Text("会修改 Ollama 服务端环境变量并重启 Ollama（进行中的对话会中断，建议空闲时执行）；修改前自动备份、可一键恢复。")
                    .font(VTheme.Typo.caption)
                    .foregroundStyle(VTheme.textTertiary)
                    .lineSpacing(2)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(VTheme.bgCard, in: RoundedRectangle(cornerRadius: VTheme.Radius.l))
            .overlay(RoundedRectangle(cornerRadius: VTheme.Radius.l).stroke(VTheme.borderSubtle))
        }
    }

    // MARK: - Ollama 环境变量区卡（读取 / 逐项编辑 / 新增 / 保存）

    @ViewBuilder
    private var envVarsCard: some View {
        if vm.isOllama {
            VStack(alignment: .leading, spacing: 12) {
                Text("Ollama 环境变量")
                    .font(VTheme.Typo.sectionTitle)
                    .foregroundStyle(VTheme.textPrimary)

                if !vm.envLoaded {
                    // 读取失败（脚本不存在/不可读）——envMessage 带中文明细
                    Text(vm.envMessage ?? "未检测到 Ollama 环境变量脚本（~/bin/set-ollama-env.sh）。")
                        .font(VTheme.Typo.caption)
                        .foregroundStyle(VTheme.textTertiary)
                } else if vm.envVars.isEmpty {
                    // 读取成功但脚本无变量（或草稿被全部删除，保存后即从脚本移除）
                    VStack(alignment: .leading, spacing: 4) {
                        Text("脚本中暂无 OLLAMA_* 变量。可在下方添加，常用配置参考：")
                            .font(VTheme.Typo.caption)
                            .foregroundStyle(VTheme.textTertiary)
                        Text("• OLLAMA_KEEP_ALIVE — 模型常驻时长（如 999h）\n• OLLAMA_NUM_PARALLEL — 并发请求数（如 4）\n• OLLAMA_CONTEXT_LENGTH — 上下文长度（如 131072）\n• OLLAMA_FLASH_ATTENTION=1 — Flash Attention 提速")
                            .font(VTheme.Typo.caption)
                            .foregroundStyle(VTheme.textTertiary)
                            .lineSpacing(2)
                    }
                } else {
                    HStack(spacing: 8) {
                        Text("变量")
                            .frame(width: 200, alignment: .leading)
                        Text("值")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(VTheme.Typo.micro)
                    .foregroundStyle(VTheme.textTertiary)

                    ForEach(vm.envVars) { item in
                        envVarRow(item)
                    }
                }

                HStack(spacing: 8) {
                    TextField("变量名（OLLAMA_…）", text: $newEnvKey)
                        .textFieldStyle(.plain).vInputStyle()
                        .font(VTheme.Typo.mono)
                    TextField("值", text: $newEnvValue)
                        .textFieldStyle(.plain).vInputStyle()
                        .font(VTheme.Typo.mono)
                    Button { addEnvVar() } label: {
                        Text("添加").font(VTheme.Typo.caption)
                    }
                    .buttonStyle(.vSecondary)
                    .controlSize(.small)
                }
                .help("常用变量：OLLAMA_KEEP_ALIVE（常驻时长如 999h）、OLLAMA_NUM_PARALLEL（并发如 4）、OLLAMA_CONTEXT_LENGTH（上下文如 131072）、OLLAMA_FLASH_ATTENTION=1（提速）")

                if vm.envDirty {
                    Text("有未保存更改——删除/改值/新增都只是草稿，点「保存并重启 Ollama」才会写入脚本；点「重读」放弃修改。")
                        .font(VTheme.Typo.caption)
                        .foregroundStyle(VTheme.danger)
                }

                HStack(spacing: 8) {
                    Button { vm.saveEnvVars() } label: {
                        Text(vm.envDirty ? "保存并重启 Ollama（有未保存更改）" : "保存并重启 Ollama")
                            .font(VTheme.Typo.caption)
                    }
                    .buttonStyle(.vPrimary)
                    .controlSize(.small)
                    .accessibilityIdentifier("inference.envSave")

                    Button { vm.loadEnvVars() } label: {
                        Text("重读").font(VTheme.Typo.caption)
                    }
                    .buttonStyle(.vSecondary)
                    .controlSize(.small)
                    .help("从脚本重新读取（放弃未保存的草稿修改）")
                    .accessibilityIdentifier("inference.envReload")
                }

                if let msg = vm.envMessage {
                    Text(msg).font(VTheme.Typo.caption).foregroundStyle(VTheme.textSecondary)
                }
                Text("读取 ~/bin/set-ollama-env.sh 中的 OLLAMA_* 变量（仅 Ollama 专属，不碰代理等其它设置）；保存会重写脚本并重启 Ollama（进行中的对话会中断）。")
                    .font(VTheme.Typo.caption)
                    .foregroundStyle(VTheme.textTertiary)
                    .lineSpacing(2)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(VTheme.bgCard, in: RoundedRectangle(cornerRadius: VTheme.Radius.l))
            .overlay(RoundedRectangle(cornerRadius: VTheme.Radius.l).stroke(VTheme.borderSubtle))
        }
    }

    private func envVarRow(_ item: NativeOllamaEnvVar) -> some View {
        HStack(spacing: 8) {
            Text(item.key)
                .font(VTheme.Typo.mono.weight(.medium))
                .foregroundStyle(VTheme.textPrimary)
                .frame(width: 200, alignment: .leading)
                .lineLimit(1)
            TextField("值", text: Binding(
                get: { vm.envVars.first(where: { $0.id == item.id })?.value ?? "" },
                set: { vm.updateEnvVar(id: item.id, value: $0) }
            ))
            .textFieldStyle(.plain)
            .vInputStyle()
            .font(VTheme.Typo.mono)
            if !item.isSynced {
                Text("生效: \(item.effective ?? "—")")
                    .font(VTheme.Typo.micro)
                    .foregroundStyle(VTheme.ok)
            }
            Button { vm.removeEnvVar(id: item.id) } label: {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(VTheme.danger)
            }
            .buttonStyle(.plain)
            .help("从草稿移除该变量；点「保存并重启 Ollama」后才会从脚本删除")
            .accessibilityIdentifier("inference.envRemove.\(item.key)")
        }
    }

    private func addEnvVar() {
        let k = newEnvKey.trimmingCharacters(in: .whitespaces)
        guard !k.isEmpty else { return }
        vm.addEnvVar(key: k, value: newEnvValue)
        newEnvKey = ""
        newEnvValue = ""
    }

    // MARK: - 推理参数与超时区卡

    private var paramsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("推理参数与超时")
                .font(VTheme.Typo.sectionTitle)
                .foregroundStyle(VTheme.textPrimary)
                .padding(.bottom, 12)

            Text("推理超时（秒，填 0 = 用默认值）")
                .font(VTheme.Typo.body)
                .foregroundStyle(VTheme.textPrimary)
                .padding(.bottom, 8)
            HStack(alignment: .top, spacing: 8) {
                timeoutField("timeout_connect", label: "连接超时", dft: 10)
                timeoutField("timeout_reading", label: "非流式读超时", dft: 300)
                timeoutField("timeout_stream_reading", label: "流式读超时", dft: 1800)
            }
            // 方向2 波次2：一行三个同名「保存」按钮合为一个「保存超时」（一次提交三个草稿值）
            Button {
                Task { await vm.saveTimeouts() }
            } label: {
                Text("保存超时").font(VTheme.Typo.caption)
            }
            .buttonStyle(.vSecondary)
            .controlSize(.small)
            .disabled(vm.busy)
            .accessibilityIdentifier("inference.saveTimeouts")
            .padding(.top, 8)
            Text("本地大参数模型（30B/35B）处理超长文本时，「非流式读超时」300s 可能偏紧——工作流推理节点走的就是它。流式（聊天）默认 1800s，覆盖思考间隙。")
                .font(VTheme.Typo.caption)
                .foregroundStyle(VTheme.textTertiary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)

            // ── 0.4.31（P2 懒加载）：模型缓存懒加载设置 ──
            Text("模型缓存懒加载")
                .font(VTheme.Typo.body)
                .foregroundStyle(VTheme.textPrimary)
                .padding(.top, 16)
                .padding(.bottom, 8)
            Toggle("启用懒加载（上下文先以低档运行，膨胀时自动升档至 num_ctx 上限）",
                   isOn: Binding(
                    get: { vm.ctxLazyEnabled },
                    set: { on in Task { await vm.setCtxLazyEnabled(on) } }))
                .font(VTheme.Typo.body)
                .foregroundStyle(VTheme.textPrimary)
                .disabled(vm.busy)
                .accessibilityIdentifier("inference.ctxLazyEnabled")
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("起始档（首次加载的上下文档位）")
                        .font(VTheme.Typo.caption)
                        .foregroundStyle(VTheme.textSecondary)
                    HStack(spacing: 6) {
                        TextField("12288", text: $vm.ctxLazyStartDraft)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13, design: .monospaced))
                            .vInputStyle()
                            .frame(maxWidth: 160)
                            .accessibilityIdentifier("inference.ctxLazyStart")
                        Button {
                            Task { await vm.saveCtxLazyStart() }
                        } label: {
                            Text("保存").font(VTheme.Typo.caption)
                        }
                        .buttonStyle(.vSecondary)
                        .controlSize(.small)
                        .disabled(vm.busy)
                        .accessibilityIdentifier("inference.saveCtxLazyStart")
                    }
                    Text("默认 12288（2048~1048576）")
                        .font(VTheme.Typo.micro)
                        .foregroundStyle(VTheme.textTertiary)
                }
            }
            .padding(.top, 8)
            Text("上限 = 下方按模型配置的 num_ctx；未配 num_ctx 的模型不受影响。仅 Ollama 与模型包生效。")
                .font(VTheme.Typo.caption)
                .foregroundStyle(VTheme.textTertiary)
                .lineSpacing(2)
                .padding(.top, 4)

            // ── 每模型推理参数（A2/A4 0.4.15）──
            Text("模型推理参数（按模型单独配置）")
                .font(VTheme.Typo.sectionTitle)
                .foregroundStyle(VTheme.textPrimary)
                .padding(.top, 20)
                .padding(.bottom, 8)
            ModelOptionsEditorView(vm: vm.optionsEditor)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(VTheme.bgCard, in: RoundedRectangle(cornerRadius: VTheme.Radius.l))
        .overlay(RoundedRectangle(cornerRadius: VTheme.Radius.l).stroke(VTheme.borderSubtle))
    }

    private func timeoutField(_ key: String, label: String, dft: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(VTheme.Typo.caption)
                .foregroundStyle(VTheme.textSecondary)
            // 方向2 波次2：字段级「保存」按钮随合并删除（统一走上方「保存超时」，
            // 原 accessibilityIdentifier inference.saveTimeout.<key> 一并退役）
            TextField("0", text: Binding(
                get: { vm.timeoutDrafts[key] ?? "0" },
                set: { vm.timeoutDrafts[key] = $0 }
            ))
            .textFieldStyle(.plain)
            .font(.system(size: 13, design: .monospaced))
            .vInputStyle()
            .accessibilityIdentifier("inference.timeout.\(key)")
            Text("默认 \(dft)s")
                .font(VTheme.Typo.micro)
                .foregroundStyle(VTheme.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 模型列表区卡

    private var modelsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("模型列表（\(vm.models.count)）")
                .font(VTheme.Typo.sectionTitle)
                .foregroundStyle(VTheme.textPrimary)

            if vm.models.isEmpty {
                // 方向2 波次2：手写空态（30px 图标+两行灰字）收编 VEmptyStateView
                //（图标卡+宋体标题+说明，L4 拍板形制）
                VEmptyStateView(icon: "cpu",
                                title: "暂无可用模型",
                                message: "后端离线或未安装模型；模型包安装并启用后也会出现在此列表（在「模型包」面板管理）")
            } else {
                // 对齐 TSX 纵向滚动区（方向2 波次2：注释对齐代码实际值 maxHeight 220，
                // 原注释误写 maxHeight:200，代码不动）
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(vm.models) { m in
                            modelRow(m)
                        }
                    }
                }
                .frame(maxHeight: 220)
            }

            if vm.isOllama {
                HStack(spacing: 8) {
                    TextField("拉取模型，如 qwen2.5-vl", text: $vm.pullName)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, design: .monospaced))
                        .vInputStyle()
                        .accessibilityIdentifier("inference.pullName")
                        .onSubmit { Task { await vm.pullModel() } }
                    Button {
                        Task { await vm.pullModel() }
                    } label: {
                        HStack(spacing: 4) {
                            if vm.busy { ProgressView().controlSize(.mini) }
                            Text("拉取").font(VTheme.Typo.caption)
                        }
                    }
                    .buttonStyle(.vPrimary)
                    .controlSize(.small)
                    .disabled(vm.busy || vm.pullName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("inference.pullButton")
                }
            } else {
                VCallout(.info, "拉取/删除模型仅 Ollama 后端支持；OpenAI 兼容后端的模型请在其服务端管理，模型包的安装、启用与卸载请在「模型包」面板进行。")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(VTheme.bgCard, in: RoundedRectangle(cornerRadius: VTheme.Radius.l))
        .overlay(RoundedRectangle(cornerRadius: VTheme.Radius.l).stroke(VTheme.borderSubtle))
    }

    private func modelRow(_ m: InferenceModelEntry) -> some View {
        HStack(spacing: 8) {
            Text(m.name)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(VTheme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            // 0.4.30（W2）来源徽标：模型包与后端模型在统一列表中可辨
            if m.isModelPack {
                Text("模型包")
                    .font(VTheme.Typo.micro)
                    .foregroundStyle(VTheme.accentText)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(VTheme.accentBg, in: RoundedRectangle(cornerRadius: VTheme.Radius.s))
                    .overlay(RoundedRectangle(cornerRadius: VTheme.Radius.s).stroke(VTheme.accent))
            }
            Spacer(minLength: 0)
            if let size = m.size, size > 0 {
                // 方向2 波次3：字节单位全仓统一 1024 系+「 %.1f GB」——改调
                // ModelPackFormat.formatSize（原版 :453 为十进制 1e9+「%.1fGB」
                // 无空格口径，与模型包面板读数不一致）。
                Text(ModelPackFormat.formatSize(size))
                    .font(VTheme.Typo.caption)
                    .foregroundStyle(VTheme.textTertiary)
            }
            if let ctx = m.context_length {
                // 方向2 波次2：裸整数补千分位分组（ctx 131072 → ctx 131,072）
                Text("ctx \(ctx.formatted(.number.grouping(.automatic)))")
                    .font(VTheme.Typo.caption)
                    .foregroundStyle(VTheme.textTertiary)
            }
            if vm.defaultModel == m.name {
                Text("当前默认")
                    .font(VTheme.Typo.micro)
                    .foregroundStyle(VTheme.ok)
            } else {
                Button {
                    Task { await vm.selectDefaultModel(m) }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "checkmark").font(.system(size: 10))
                        Text("设为默认").font(VTheme.Typo.caption)
                    }
                }
                .buttonStyle(.vGhost)
                .controlSize(.small)
                .foregroundStyle(VTheme.textTertiary)
                .help(m.isModelPack
                      ? "选为默认模型（模型包对话时会暂停其它本地模型——换装编排）"
                      : "选为默认模型")
                .accessibilityIdentifier("inference.setDefault.\(m.name)")
            }
            Button {
                Task { await vm.configureParams(for: m.name) }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "slider.horizontal.3").font(.system(size: 10))
                    Text("参数").font(VTheme.Typo.caption)
                }
            }
            .buttonStyle(.vGhost)
            .controlSize(.small)
            .foregroundStyle(vm.modelOptions[m.name] != nil ? VTheme.accent : VTheme.textTertiary)
            .help("配置该模型的 num_ctx / temperature 等推理参数")
            .accessibilityIdentifier("inference.params.\(m.name)")
            if vm.isOllama && !m.isModelPack && (vm.status?.capabilities.delete ?? false) {
                Button {
                    Task { await vm.deleteModel(m.name) }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "trash").font(.system(size: 10))
                        Text("删除").font(VTheme.Typo.caption)
                    }
                }
                .buttonStyle(.vGhost)
                .controlSize(.small)
                .foregroundStyle(VTheme.dangerText)
                .accessibilityIdentifier("inference.delete.\(m.name)")
            }
        }
        .padding(.vertical, 5)
        .overlay(alignment: .bottom) {
            Divider().overlay(VTheme.borderSubtle)
        }
    }
}

/// 方向2 波次2：后端单选卡（原 backendRadioCard 函数体，为承载 hover 态抽成 struct）——
/// 补 hover 底色反馈（hovering 且未选中时 bgHover，选中态 accentBg 优先不叠加）与
/// .isSelected 无障碍 trait；选中态 accent 2px 描边保持不动。
private struct BackendRadioCard: View {
    let title: String
    let subtitle: String
    let selected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 13))
                    .foregroundStyle(selected ? VTheme.accent : VTheme.textTertiary)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(VTheme.textPrimary)
                    Text(subtitle)
                        .font(VTheme.Typo.caption)
                        .foregroundStyle(VTheme.textTertiary)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? VTheme.accentBg : (isHovered ? VTheme.bgHover : VTheme.bgCard),
                        in: RoundedRectangle(cornerRadius: VTheme.Radius.m))
            .overlay(RoundedRectangle(cornerRadius: VTheme.Radius.m)
                .stroke(selected ? VTheme.accent : VTheme.borderDefault,
                        lineWidth: selected ? 2 : 1))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(VTheme.Motion.micro, value: isHovered)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("inference.backend.\(title)")
    }
}

// 方向2 波次2：PanelMessageKind（ViewModel 产出）→ VCalloutKind 映射。
private extension PanelMessageKind {
    var calloutKind: VCalloutKind {
        switch self {
        case .info: return .info
        case .success: return .success
        case .error: return .error
        }
    }
}
