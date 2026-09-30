//
//  SettingsPanelView.swift
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

//  基础设置分区表单。分区结构与行为逐段对照
//  subagent/renderer/src/panels/SettingsPanel.tsx（0.4.34）：
//    顶部：错误/成功提示条 + 打开日志/数据目录（不依赖配置加载状态）
//    基础            默认模型（下拉/手动回退）/ max_tool_rounds（1-1000）
//                    （0.5.1 R1：data_root 字段移出——曾由「关于」页承接；
//                     0.7.1 Bug 7 起数据根显示与修改收编本页底部「诊断」区）
//    诊断（底部）    0.7.1 Bug 7：原「关于」页诊断能力平移——运行时状态 /
//                    数据根显示与修改 / 日志与数据根目录入口 / 调试 mock（id 不变）
//    稳定性          重连(1-10) / 心跳(5-60) / 权限确认等待(0-86400，0=无限) / auth_grants 只读清单+逐条移除
//    并发与调度      model_parallel / task_concurrency / delegation_model_swap（勾选即存）
//    报错分析        error_analysis_model（下拉，空=跟随默认，切换即存）
//    应用内模块控制  app_control_enabled + app_control_confirm 动作勾选（7 动作注册表）
//    模型特长        model_strengths（可用∪已配置并集，失效标记，单条 100 字，独立保存）
//    网络            代理引导 / proxy_http_port / network_switch(auto|proxy) /
//                    confirm_network_install / confirm_model_pack_download / 需代理名单
//    插件仓库        plugin_repos 增删
//    上下文管理      compact_archive_dir / allow_auto_compact / compact_keep_recent(2-100) / 压缩记录
//    多 Agent        auto_create_sub_agents（缺省 true）
//    导出与附件      default_export_dir / vision_parse_attachments
//    底部            保存全部（整包回写）/ 重新加载 / 配置文件路径
//
//  V4：Computer Use 区抽出为设置覆盖页独立「CU」分区（SettingsCUView.swift），
//  基础设置不再重复展示（tsx 原本嵌在 general 内，SettingsPanel.tsx:732；
//  原生内部导航拆分为有意偏差，CU 宏仍留流程中心）。
//
//  视觉：VTheme 近似（不追求像素级复刻）。日志/数据目录入口与原 AboutPanel 同口径
//  （AppLogger 目录 + 数据根；Electron 版走 bridge 开侧车目录，见汇报差异说明）。
//

import SwiftUI
import AppKit

public struct SettingsPanelView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var vmBox = SettingsViewModelBox()

    public init() {}

    public var body: some View {
        if let vm = vmBox.vm {
            SettingsPanelBody(vm: vm)
        } else {
            VLoadingView("设置加载中…")
                .task { vmBox.attach(appState: appState) }
        }
    }
}

/// 延迟构建 SettingsViewModel（需要已注入的 AppState；同 ChatViewModelBox 模式）。
@MainActor
final class SettingsViewModelBox: ObservableObject {
    @Published var vm: SettingsViewModel?
    func attach(appState: AppState) {
        if vm == nil {
            vm = SettingsViewModel(
                clientProvider: { [weak appState] in
                    appState?.runtime.client as? SettingsPanelClient
                },
                sessionIdProvider: { [weak appState] in appState?.currentSessionId },
                logger: appState.logger
            )
        }
    }
}

// MARK: - 面板主体

private struct SettingsPanelBody: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var vm: SettingsViewModel
    // 0.5.1 R1：原 @ObservedObject runtime 随「原生内核」区块一并移除（目录按钮与
    // 配置文件路径均经 appState.runtime 读取，无需面板级观察）。

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // ── 保存结果反馈（tsx calloutStyle error/success）──
                if let err = vm.errorMessage {
                    VCallout(.error, err)
                        .accessibilityIdentifier("settings.errorCallout")
                }
                if let msg = vm.message {
                    VCallout(.success, msg)
                        .accessibilityIdentifier("settings.successCallout")
                }

                // ── 日志 / 数据目录（顶层渲染，配置未加载也可点；tsx 问题5修复口径）──
                directoryButtons

                // 0.5.1 R1：「原生内核」路由表展示区块已移除（用户实测：侧车归零后
                // 「原生内核」对用户无意义且与关于页重叠；诊断价值归零，不搬入关于页）

                if vm.config == nil {
                    loadingState
                } else {
                    BasicSection(vm: vm)
                    StabilitySection(vm: vm)
                    ConcurrencySection(vm: vm)
                    ErrorAnalysisSection(vm: vm)
                    AppControlSection(vm: vm)
                    // V4：Computer Use 区已抽为覆盖页独立「CU」分区（SettingsCUView）
                    ModelStrengthsSection(vm: vm)
                    NetworkSection(vm: vm)
                    PluginReposSection(vm: vm)
                    ContextSection(vm: vm)
                    MultiAgentSection(vm: vm)
                    ExportSection(vm: vm)
                    bottomBar
                }

                // 0.7.1 Bug 7（业主拍板方案 A）：原「关于」页的诊断能力收编为基础设置
                // 底部「诊断」区（运行时状态 / 数据根显示与修改 / 日志与数据根目录入口 /
                // 调试 mock）。AX id 全部保留不变（冒烟脚本与测试引用）；不依赖配置
                // 加载状态，与目录按钮同口径恒渲染。
                DiagnosticsSection(runtime: appState.runtime)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(VTheme.bgApp)
        .onAppear { vm.onAppear() }
        // 侧车就绪竞态自愈：面板先于侧车打开时 load 会失败（Electron 线由主进程
        // gate 掉此竞态；原生线 UI 与侧车同起），就绪后自动重载一次。
        // P3-W6⑤：nativeReady 于 runtime init 同步点亮、任何视图出现前恒 true，
        // 旧「就绪自愈」onChange（永不触发）随侧车归零删除——首拉在挂载链路上。
    }

    /// 日志与数据目录是两个不同目录（tsx 0.4.12 C1：数据目录≠缓存，提示列全内容与风险）。
    private var directoryButtons: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Button {
                    appState.logger.openLogDirectory()
                } label: {
                    Label("打开日志文件夹", systemImage: "folder")
                }
                .buttonStyle(.vSecondary)
                .accessibilityIdentifier("settings.openLogsButton")
                HintText("应用运行日志（app.log），排查报错看这里。")
            }
            VStack(alignment: .leading, spacing: 3) {
                Button {
                    NSWorkspace.shared.open(URL(fileURLWithPath: appState.runtime.dataRootPath))
                } label: {
                    Label("打开数据目录", systemImage: "externaldrive")
                }
                .buttonStyle(.vSecondary)
                .accessibilityIdentifier("settings.openDataDirButton")
                HintText("应用数据根目录（应用隔离数据根）：项目与会话数据库、知识仓库索引与全局知识、已下载的模型（如语义检索用的 bge-m3）、技能与插件、config.json 配置。⚠️ 这里是核心数据不是缓存，删除会丢失项目、会话与知识库，请勿随意清理。")
            }
        }
    }

    private var loadingState: some View {
        Group {
            if vm.errorMessage != nil {
                VEmptyStateView(icon: "exclamationmark.triangle",
                                title: "读取配置失败",
                                message: "配置读取失败（内核或数据根不可用）。请稍后点「重新加载」重试。")
                Button("重试") { Task { await vm.load() } }
                    .buttonStyle(.vSecondary)
                    .accessibilityIdentifier("settings.retryButton")
            } else {
                VLoadingView("加载配置中…")
            }
        }
    }

    private var bottomBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    Task { await vm.saveAll() }
                } label: {
                    Label("保存全部", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.vPrimary)
                .disabled(vm.saving)
                .accessibilityIdentifier("settings.saveAllButton")
                Button {
                    Task { await vm.load() }
                } label: {
                    Label("重新加载", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.vSecondary)
                .disabled(vm.saving)
                .accessibilityIdentifier("settings.reloadButton")
            }
            // tsx：配置文件：{getInjected().configPath || '~/.subagent/config.json'}
            Text("配置文件：\(appState.runtime.dataRootPath)/config.json")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(VTheme.textTertiary)
                .textSelection(.enabled)
        }
    }
}

// MARK: - 通用小组件

/// 分区卡（对标 tsx sectionCard = cardL + padding 16/20）。
struct SectionCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(VTheme.Typo.sectionTitle)
                .foregroundStyle(VTheme.textPrimary)
                .padding(.bottom, 12)
            content()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(VTheme.bgCard, in: RoundedRectangle(cornerRadius: VTheme.Radius.l))
        .overlay(RoundedRectangle(cornerRadius: VTheme.Radius.l).stroke(VTheme.borderSubtle))
    }
}

/// 表单标签（tsx formLabel：12 号次要文字，上间距 10）。
struct FormLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(VTheme.Typo.caption)
            .foregroundStyle(VTheme.textSecondary)
            .padding(.top, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 提示文字（tsx hintStyle = typo.micro）。
struct HintText: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(VTheme.Typo.micro)
            .foregroundStyle(VTheme.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 3)
    }
}

/// 名单行（等宽字体 + 尾部删除按钮）。
struct ListRow: View {
    let text: String
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text(text)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(VTheme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            Button(action: onRemove) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.vGhost)
            .controlSize(.small)
            .foregroundStyle(VTheme.textTertiary)
        }
        .padding(.bottom, 4)
    }
}

/// 名单追加输入行（输入框 + 添加按钮）。
struct ListAddRow: View {
    @Binding var text: String
    let placeholder: String
    var addDisabled: Bool = false
    let onAdd: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .vInputStyle()
                .onSubmit { if !addDisabled { onAdd() } }
            Button("添加", action: onAdd)
                .buttonStyle(.vSecondary)
                .controlSize(.small)
                .disabled(addDisabled)
        }
        .padding(.top, 4)
    }
}

// MARK: - 基础

/// 默认模型「真不可用」指引文案（nil = 不显示；internal 供单测直取）。
/// 三分支口径：
///   ① 列表为空（推理后端未连接 / 拉取失败）→ 连接指引，恢复后自动可用；
///   ② 列表非空但归一化（ModelIdentity）仍不命中 → 模型已移除指引，
///      当前默认值保留、恢复后自动生效；
///   ③ 命中（含 ":latest" 互认）或正在拉取 → nil（Picker 标签「（当前不可用）」
///      的显示口径同在 Picker 处，本函数只管说明文案）。
func defaultModelUnavailableHint(current: String, options: [String], loading: Bool) -> String? {
    guard !current.isEmpty, !loading else { return nil }
    if options.isEmpty {
        return "当前无法连接推理后端，请确认后端已启动；恢复后该模型自动可用。"
    }
    guard !ModelIdentity.isAvailable(current, in: options) else { return nil }
    return "该模型已不在本机可用列表中（可能已被删除或未安装）。"
        + "可前往「推理后端」页重新拉取同名模型，或改选其他可用模型；"
        + "当前默认值会保留，模型恢复后自动生效。"
}

private struct BasicSection: View {
    @ObservedObject var vm: SettingsViewModel

    var body: some View {
        SectionCard(title: "基础") {
            // 默认模型：下拉（有可用模型时）/ 手动输入回退（tsx checkpoint-053）
            FormLabel("默认模型")
            if !vm.modelOptions.isEmpty {
                Picker("默认模型", selection: Binding(
                    get: { vm.config?.defaultModel ?? "" },
                    set: { vm.setDraftString(SidecarConfig.Key.defaultModel, $0) }
                )) {
                    let current = vm.config?.defaultModel ?? ""
                    // 归一化口径（ollama ":latest" 互认）——否则 "qwen3.8" 会被
                    // 可用列表里的 "qwen3.8:latest" 误判「当前不可用」
                    if !current.isEmpty && !ModelIdentity.isAvailable(current, in: vm.modelOptions) {
                        Text("\(current)（当前不可用）").tag(current)
                    }
                    ForEach(vm.modelOptions, id: \.self) { m in
                        Text(m).tag(m)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("settings.defaultModelPicker")
            } else {
                TextField(vm.modelsLoading ? "正在拉取可用模型…" : "无可用模型，可手动输入",
                          text: Binding(
                            get: { vm.config?.defaultModel ?? "" },
                            set: { vm.setDraftString(SidecarConfig.Key.defaultModel, $0) }))
                    .textFieldStyle(.plain)
                    .vInputStyle()
                    .accessibilityIdentifier("settings.defaultModelField")
            }
            // 真不可用时的用户指引（归一化后仍不命中才显示；三分支口径见函数注释）
            if let unavailableHint = defaultModelUnavailableHint(
                current: vm.config?.defaultModel ?? "",
                options: vm.modelOptions, loading: vm.modelsLoading) {
                HintText(unavailableHint)
                    .accessibilityIdentifier("settings.defaultModelUnavailableHint")
            }
            HintText("从当前推理后端拉取的可用模型中选择；列表为空时可手动输入。")

            // 0.5.1 R1：「数据根目录 data_root」字段移除——数据根显示与修改
            // 现由本页底部「诊断」区承接（DiagnosticsSection 写 runtime.dataRootPath，
            // UserDefaults 持久化、下次启动生效；0.7.1 Bug 7 前在「关于」页）。
            // config.data_root 键仍在 config.json 内随整包回写保留（移除字段不丢键，
            // 见 SettingsR1Tests）。

            FormLabel("工具调用最大轮次（Agent 单次对话最多调用工具的次数）")
            TextField("", text: $vm.draftMaxToolRounds)
                .textFieldStyle(.plain)
                .vInputStyle()
                .accessibilityIdentifier("settings.maxToolRoundsField")
            HintText("默认 200，范围 1-1000。轮次越大，Agent 可执行越复杂的任务，但也消耗更多 token。无效空转有独立防护（连续失败自动停止、重复搜索自动拦截），无需靠轮次上限兜底")
        }
    }
}

// MARK: - 稳定性

private struct StabilitySection: View {
    @ObservedObject var vm: SettingsViewModel

    /// 权限确认等待时长的动态提示（tsx L623-626：读当前值分叉文案）。
    private var authTimeoutHint: String {
        let v = Double(vm.draftAuthConfirmTimeout) ?? vm.config?.authConfirmTimeout ?? 600
        if v == 0 {
            return "当前：无限等待——你随时回来点确认都有效，不会被误判为拒绝。"
        }
        return "当前：\(Int((v / 60).rounded())) 分钟内未确认将按拒绝处理。"
    }

    var body: some View {
        SectionCard(title: "稳定性") {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 0) {
                    FormLabel("断线重连次数")
                    TextField("", text: $vm.draftReconnectMaxAttempts)
                        .textFieldStyle(.plain)
                        .vInputStyle()
                        .accessibilityIdentifier("settings.reconnectField")
                }
                VStack(alignment: .leading, spacing: 0) {
                    FormLabel("心跳间隔（秒）")
                    TextField("", text: $vm.draftHeartbeatInterval)
                        .textFieldStyle(.plain)
                        .vInputStyle()
                        .accessibilityIdentifier("settings.heartbeatField")
                }
            }
            HintText("重连次数：网络错误时自动重试的最大次数（1-10）。心跳间隔：长任务保活的基础间隔（5-60 秒，实际按事件节奏动态调整）")

            // 0.4.12（B2）：权限确认弹窗等待时长，0 = 无限等待
            FormLabel("权限确认等待时长（秒）")
            TextField("", text: $vm.draftAuthConfirmTimeout)
                .textFieldStyle(.plain)
                .vInputStyle()
                .accessibilityIdentifier("settings.authTimeoutField")
            HintText("Agent 请求敏感操作（删除系统文件、联网安装、Computer Use 点击输入等）时弹窗等你确认的时长。超时未点＝按「拒绝」处理。填 0 = 无限等待（永不超时，只能自己关闭弹窗）。\(authTimeoutHint)")

            // R2（0.4.33）：已永久授权的工具——只读清单 + 逐条移除
            FormLabel("已永久授权的工具")
            let grants = vm.config?.authGrants ?? []
            if grants.isEmpty {
                HintText("暂无。授权弹窗中点「永久允许」后，对应工具会列在这里。")
            } else {
                VStack(spacing: 6) {
                    ForEach(grants) { g in
                        HStack(spacing: 8) {
                            Text("\(g.tool) · \(g.action)")
                                .font(.system(size: 12.5, design: .monospaced))
                                .foregroundStyle(VTheme.textPrimary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer(minLength: 0)
                            Text(g.granted_at ?? "")
                                .font(VTheme.Typo.micro)
                                .foregroundStyle(VTheme.textTertiary)
                            Button("移除") { vm.removeAuthGrant(g) }
                                .buttonStyle(.vSecondary)
                                .controlSize(.small)
                                .accessibilityIdentifier("settings.removeGrant.\(g.id)")
                        }
                    }
                }
                .padding(.top, 4)
            }
            HintText("点「移除」后，该工具下次触发敏感操作时重新弹窗询问。联网安装永不进入本清单（安全敏感，每次必问）。")
        }
    }
}

// MARK: - 并发与调度

private struct ConcurrencySection: View {
    @ObservedObject var vm: SettingsViewModel

    var body: some View {
        SectionCard(title: "并发与调度") {
            Toggle("大模型并行", isOn: Binding(
                get: { vm.config?.modelParallel ?? false },
                set: { vm.saveBool(SidecarConfig.Key.modelParallel, $0) }))
                .toggleStyle(.checkbox)
                .accessibilityIdentifier("settings.modelParallelToggle")
            HintText("开启后多个模型可同时运行（消耗更多内存）；关闭时切换模型会等待 5s 让旧模型释放（Ollama 无 unload API，等待 GC）。")

            Toggle("任务并发", isOn: Binding(
                get: { vm.config?.taskConcurrency ?? false },
                set: { vm.saveBool(SidecarConfig.Key.taskConcurrency, $0) }))
                .toggleStyle(.checkbox)
                .padding(.top, 8)
                .accessibilityIdentifier("settings.taskConcurrencyToggle")
            HintText("开启后多个委派任务可并行执行；关闭时任务排队依次运行（串行排队，本机性能受限时推荐关闭）。")

            Toggle("委派模型换装", isOn: Binding(
                get: { vm.config?.delegationModelSwap ?? true },
                set: { vm.saveBool(SidecarConfig.Key.delegationModelSwap, $0) }))
                .toggleStyle(.checkbox)
                .padding(.top, 8)
                .accessibilityIdentifier("settings.delegationSwapToggle")
            HintText("委派前卸载主模型、子 Agent 交卷后卸载子模型，腾出内存给子任务独占（本地内存有限时推荐开启）。开启「大模型并行」或「任务并发」时自动失效——并行场景卸载会互相冲突。已内置 0.4.7 事故防护：卸载带 20s 独立超时，且卸载前先确认模型确在内存（避免为卸载而加载）。")
        }
    }
}

// MARK: - 报错分析

private struct ErrorAnalysisSection: View {
    @ObservedObject var vm: SettingsViewModel

    var body: some View {
        SectionCard(title: "报错分析") {
            FormLabel("报错分析模型")
                .padding(.top, 0)
            Picker("报错分析模型", selection: Binding(
                get: { vm.config?.errorAnalysisModel ?? "" },
                set: { vm.saveErrorAnalysisModel($0) }
            )) {
                Text("（跟随默认模型：\(vm.config?.defaultModel.isEmpty == false ? vm.config?.defaultModel ?? "" : "未设置")）").tag("")
                let current = vm.config?.errorAnalysisModel ?? ""
                if !current.isEmpty && !ModelIdentity.isAvailable(current, in: vm.modelOptions) {
                    Text(current).tag(current)
                }
                ForEach(vm.modelOptions, id: \.self) { m in
                    Text(m).tag(m)
                }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("settings.errorAnalysisPicker")
            HintText("任务失败时，除显示具体原因（工具名 / 参数 / 真实错误）外，再用该模型给出一句人话诊断与下一步建议。当前模型是 OCR 等专用小模型、不具备分析能力时，会自动改用它来分析——这正是本项的用途。留空则跟随默认模型；分析失败或超时 60s 会静默跳过，只显示失败原因，不影响原始报错。")
        }
    }
}

// MARK: - 应用内模块控制

private struct AppControlSection: View {
    @ObservedObject var vm: SettingsViewModel

    /// 与后端 app_modules/registry.py 的 APP_MODULE_REGISTRY 保持一致（tsx 同名单）。
    static let allModuleActions = [
        "workflow_list", "workflow_run", "workflow_get_runs",
        "knowledge_search", "knowledge_inject", "knowledge_groups",
        "roundtable_create",
    ]

    var body: some View {
        SectionCard(title: "应用内模块控制") {
            Toggle("允许 Agent 调动应用内模块", isOn: Binding(
                get: { vm.config?.appControlEnabled ?? false },
                set: { vm.saveBool(SidecarConfig.Key.appControlEnabled, $0) }))
                .toggleStyle(.checkbox)
                .accessibilityIdentifier("settings.appControlToggle")
            HintText("开启后：Agent 可通过 app_control 调用工作流（跑确定性流程，如批量识图）、知识仓库（查历史沉淀）、圆桌（发起多 Agent 会诊）。其中查询类动作直接执行；运行工作流／创建圆桌等高成本动作会先弹窗请你确认。关闭时（默认）：该工具不会出现在 Agent 的工具列表里（零开销），Agent 无法调动任何应用内模块。以后新增模块只需在注册表登记一条，Agent 自动获得调用能力。")

            FormLabel("需要我确认的动作")
            ForEach(Self.allModuleActions, id: \.self) { action in
                Toggle(action, isOn: Binding(
                    get: { (vm.config?.appControlConfirm ?? []).contains(action) },
                    set: { vm.setAppControlConfirm(action, on: $0) }))
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12.5, design: .monospaced))
                    .padding(.bottom, 2)
                    .accessibilityIdentifier("settings.appControlConfirm.\(action)")
            }
            HintText("勾选的动作在执行前会弹窗请你确认（默认勾选运行工作流与创建圆桌两项高成本动作）；取消勾选则直接执行。查询类动作建议保持不勾选。")
        }
    }
}

// MARK: - 模型特长（0.4.9 3.47.2）

private struct ModelStrengthsSection: View {
    @ObservedObject var vm: SettingsViewModel

    /// 列表 = 实时可用模型 ∪ 已配置模型（tsx 0.4.10：并集防"界面消失但配置残留"）。
    private var allModels: [String] {
        let avail = vm.modelOptions
        let configured = Array(vm.config?.modelStrengths.keys ?? [:].keys)
        return avail + configured.filter { !avail.contains($0) }
    }

    private func isStale(_ model: String) -> Bool {
        // 归一化口径（ollama ":latest" 互认）——配置的 "qwen3.8" 不因列表
        // 里是 "qwen3.8:latest" 而误标「已不可用」
        !vm.modelOptions.isEmpty && !ModelIdentity.isAvailable(model, in: vm.modelOptions)
    }

    var body: some View {
        SectionCard(title: "模型特长（委派时按此自选模型）") {
            HintText("描述每个本地模型擅长什么，主 Agent 委派子任务时会自动按特长挑模型——例如把图片识别派给 OCR 专用小模型、把长文推理留给大模型。留空则不注入（主 Agent 沿用默认模型）。单条上限 100 字。")
                .padding(.top, 0)

            ForEach(allModels, id: \.self) { model in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(model)
                            .font(VTheme.Typo.caption)
                            .foregroundStyle(VTheme.textSecondary)
                        if isStale(model) {
                            Text("已不可用（未注入，可保留待恢复或删除）")
                                .font(VTheme.Typo.micro)
                                .foregroundStyle(VTheme.textTertiary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(VTheme.bgSidebar, in: RoundedRectangle(cornerRadius: VTheme.Radius.s))
                            Spacer()
                            Button {
                                vm.setStrength(model, "")
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.vGhost)
                            .controlSize(.small)
                            .foregroundStyle(VTheme.textTertiary)
                            .help("删除该模型的特长记录")
                        }
                        Spacer(minLength: 0)
                    }
                    TextField(isStale(model)
                              ? "（该模型当前不可用，特长已保留；重新下载后自动生效）"
                              : "如：OCR/图片转写专用，小而快",
                              text: Binding(
                                get: { vm.strengthsDraft[model] ?? "" },
                                set: { vm.setStrength(model, $0) }))
                        .textFieldStyle(.plain)
                        .vInputStyle()
                }
                .padding(.top, 8)
            }

            let staleCount = allModels.filter(isStale).count
            if staleCount > 0 {
                HintText("有 \(staleCount) 个模型的特长当前不会注入提示词（模型已从本机移除）。记录已保留——重新下载同名模型后会自动恢复生效。要彻底清除请点右侧删除图标后保存。")
            }
            if allModels.isEmpty {
                HintText("当前推理后端没有可用模型（或未连接）。连上后即可在此填写特长。")
            }

            Button {
                Task { await vm.saveStrengths() }
            } label: {
                Text("保存模型特长")
            }
            .buttonStyle(.vPrimary)
            .padding(.top, 6)
            .accessibilityIdentifier("settings.saveStrengthsButton")
        }
    }
}

// MARK: - 网络

private struct NetworkSection: View {
    @ObservedObject var vm: SettingsViewModel

    var body: some View {
        SectionCard(title: "网络") {
            // 代理引导（tsx 问题8：两态分别说清楚）
            VStack(alignment: .leading, spacing: 4) {
                Text("怎么选？").font(VTheme.Typo.caption.weight(.semibold))
                Text("· 关闭全量联网（默认「标准」）：可以正常上网——国内网站、以及不需要代理就能访问的境外网站都能正常触达；只有\"必须经代理才能连接\"的境外网站访问不到（会自动跳过、不空转）。")
                Text("· 开启全量联网（「全量」）：触达所有网站，包括海外原本受限的网站。需先在电脑启动代理软件（Clash / 小飞机等），端口填代理软件的本地监听端口（Clash 默认 HTTP 端口 7890；在代理软件\"端口/设置\"里查看）。国内网站在两种模式下都始终直连，不经代理。")
            }
            .font(VTheme.Typo.caption)
            .foregroundStyle(VTheme.textTertiary)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(VTheme.bgSidebar, in: RoundedRectangle(cornerRadius: VTheme.Radius.s))
            .padding(.bottom, 10)

            FormLabel("HTTP 代理端口（仅「全量」模式生效）")
                .padding(.top, 0)
            TextField("", text: $vm.draftProxyHTTPPort)
                .textFieldStyle(.plain)
                .vInputStyle()
                .frame(maxWidth: 220, alignment: .leading)
                .accessibilityIdentifier("settings.proxyPortField")
            // SOCKS 端口入口 0.4.26 起隐藏（后端零消费，键保留作未来预留）——tsx 同

            FormLabel("联网范围（境外网站）")
            Picker("联网范围", selection: Binding(
                get: { vm.config?.networkSwitchDisplay ?? "auto" },
                set: { vm.saveNetworkSwitch($0) }
            )) {
                Text("标准（默认）：国内 + 免代理境外站正常触达，需代理的境外站访问不到").tag("auto")
                Text("全量：触达所有网站（含海外受限站），需先启动代理软件").tag("proxy")
            }
            .labelsHidden()
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("settings.networkSwitchPicker")
            HintText("标准＝不主动走代理：能直连的都直连，连不上的境外站自动暂停重试防空转；全量＝境外请求都经代理端口，可达受限站")

            Toggle("联网安装插件/技能前必须询问我", isOn: Binding(
                get: { vm.config?.confirmNetworkInstall ?? true },
                set: { vm.saveBool(SidecarConfig.Key.confirmNetworkInstall, $0) }))
                .toggleStyle(.checkbox)
                .padding(.top, 10)
                .accessibilityIdentifier("settings.confirmNetInstallToggle")
            HintText("开启后，Agent 要从外部仓库（如 GitHub）下载安装插件或技能时，会先弹窗告知下载来源与类型，你同意才联网；当前为标准联网模式时还会一并询问是否切换到全量联网。强烈建议保持开启——曾发生子 Agent 擅自联网拉取、弹出账号密码窗并装入两个无关插件的事故。")

            // 0.4.29：模型包下载确认
            Toggle("下载模型包前必须询问我", isOn: Binding(
                get: { vm.config?.confirmModelPackDownload ?? true },
                set: { vm.saveBool(SidecarConfig.Key.confirmModelPackDownload, $0) }))
                .toggleStyle(.checkbox)
                .padding(.top, 10)
                .accessibilityIdentifier("settings.confirmPackDownloadToggle")
            HintText("开启后（默认），在「模型包」页从目录安装模型包前会弹窗告知包名、版本、大小、SHA256 与下载来源，你同意才联网下载；来源为境外站点且当前是标准联网模式时，还会一并询问是否切换到全量联网。")

            // B11（0.4.13）：「需代理」名单（白名单制已废，语义=标准模式下拒绝直连）
            FormLabel("需代理名单（仅标准模式生效，支持 *.xxx 通配）")
            let list = vm.config?.egressProxyRequired ?? []
            ForEach(list, id: \.self) { entry in
                ListRow(text: entry) { vm.removeProxyRequired(entry) }
            }
            if list.isEmpty {
                Text("（空）")
                    .font(VTheme.Typo.micro)
                    .foregroundStyle(VTheme.textTertiary)
                    .padding(.bottom, 4)
            }
            ListAddRow(text: $vm.newProxyRequired,
                       placeholder: "如 openai.com 或 *.github.com",
                       addDisabled: vm.newProxyRequired.trimmingCharacters(in: .whitespaces).isEmpty) {
                vm.addProxyRequired()
            }
            HintText("名单内的域名在标准模式下不再尝试直连（直接提示切换到全量），避免反复空等超时；切到全量模式后名单不生效，这些域名照常经代理访问。境内网站（.cn/内网/localhost）始终直连，无需也不应加入名单。标准模式下某个境外站连续访问失败时，会自动记入本名单。")
        }
    }
}

// MARK: - 插件仓库

private struct PluginReposSection: View {
    @ObservedObject var vm: SettingsViewModel

    var body: some View {
        SectionCard(title: "插件仓库") {
            FormLabel("插件仓库（可追加）")
                .padding(.top, 0)
            ForEach(vm.config?.pluginRepos ?? [], id: \.self) { repo in
                ListRow(text: repo) { vm.removePluginRepo(repo) }
            }
            ListAddRow(text: $vm.newRepo,
                       placeholder: "https://github.com/owner/repo 或本地路径",
                       addDisabled: vm.newRepo.trimmingCharacters(in: .whitespaces).isEmpty) {
                vm.addPluginRepo()
            }
        }
    }
}

// MARK: - 上下文管理

private struct ContextSection: View {
    @ObservedObject var vm: SettingsViewModel

    var body: some View {
        SectionCard(title: "上下文管理") {
            FormLabel("压缩归档目录")
                .padding(.top, 0)
            TextField("~/.subagent/compressed", text: Binding(
                get: { vm.config?.compactArchiveDir ?? "" },
                set: { vm.setDraftString(SidecarConfig.Key.compactArchiveDir, $0) }))
                .textFieldStyle(.plain)
                .vInputStyle()
                .accessibilityIdentifier("settings.compactDirField")
            HintText("智能压缩时，被摘要的消息会以 MD 文件先存到这里")

            // 问题3修复口径：勾选即保存（单键）
            Toggle("允许自动压缩", isOn: Binding(
                get: { vm.config?.allowAutoCompact ?? false },
                set: { vm.saveBool(SidecarConfig.Key.allowAutoCompact, $0) }))
                .toggleStyle(.checkbox)
                .padding(.top, 8)
                .accessibilityIdentifier("settings.allowAutoCompactToggle")
            HintText("勾选后，上下文接近上限时系统可自动执行智能压缩；不勾选则只在预警时等你手动选择")

            FormLabel("压缩保留条数（保护最近 N 条消息不动）")
            TextField("", text: $vm.draftCompactKeepRecent)
                .textFieldStyle(.plain)
                .vInputStyle()
                .frame(maxWidth: 220, alignment: .leading)
                .accessibilityIdentifier("settings.compactKeepField")

            Button {
                Task { await vm.saveContextSection() }
            } label: {
                Label("保存上下文管理", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.vPrimary)
            .padding(.top, 10)
            .accessibilityIdentifier("settings.saveContextButton")

            compactLogBlock
        }
    }

    /// M2 压缩记录（tsx CompactLogSection：null 不渲染 / 空=暂无 / 非空逐条）。
    @ViewBuilder
    private var compactLogBlock: some View {
        if let logs = vm.compactLogs {
            if logs.isEmpty {
                Text("暂无压缩记录")
                    .font(VTheme.Typo.micro)
                    .foregroundStyle(VTheme.textTertiary)
                    .padding(.top, 8)
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    Text("最近压缩记录")
                        .font(VTheme.Typo.caption)
                        .foregroundStyle(VTheme.textTertiary)
                    ForEach(logs) { entry in
                        HStack(spacing: 0) {
                            Text("\(entry.ts) · \(entry.beforeTokens.map { String($0) } ?? "?")→\(entry.afterTokens.map { String($0) } ?? "?") tok · \(entry.archivePath ?? "无归档")")
                                .foregroundStyle(VTheme.textTertiary)
                            if let error = entry.error {
                                Text(" · \(error)")
                                    .foregroundStyle(VTheme.dangerText)
                            }
                        }
                        .font(VTheme.Typo.micro)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.top, 10)
            }
        }
    }
}

// MARK: - 多 Agent

private struct MultiAgentSection: View {
    @ObservedObject var vm: SettingsViewModel

    var body: some View {
        SectionCard(title: "多 Agent") {
            // tsx：checked = auto_create_sub_agents !== false（缺省 true）；勾选即存
            Toggle("允许主 Agent 自动新建子 Agent", isOn: Binding(
                get: { vm.config?.autoCreateSubAgents ?? true },
                set: { vm.saveBool(SidecarConfig.Key.autoCreateSubAgents, $0) }))
                .toggleStyle(.checkbox)
                .accessibilityIdentifier("settings.autoSubAgentsToggle")
            HintText("开启后，委派目标不存在且任务书带\"建议角色\"时，系统会自动新建该角色的子 Agent 并执行；关闭后，委派目标不存在时将转述给你手动决定。")

            Button {
                Task { await vm.saveMultiAgentSection() }
            } label: {
                Label("保存多 Agent 设置", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.vPrimary)
            .padding(.top, 10)
            .accessibilityIdentifier("settings.saveMultiAgentButton")
        }
    }
}

// MARK: - 导出与附件

private struct ExportSection: View {
    @ObservedObject var vm: SettingsViewModel

    var body: some View {
        SectionCard(title: "导出与附件") {
            FormLabel("默认导出目录")
                .padding(.top, 0)
            TextField("留空 = 各项目的工作目录", text: Binding(
                get: { vm.config?.defaultExportDir ?? "" },
                set: { vm.setDraftString(SidecarConfig.Key.defaultExportDir, $0) }))
                .textFieldStyle(.plain)
                .vInputStyle()
                .accessibilityIdentifier("settings.exportDirField")
            HintText("圆桌导出 / 交卷报告 / 会话导出统一保存到该目录。留空则存到各项目自己的工作目录。知识库与记忆始终跟项目走，不受此配置影响。")

            // 问题4修复口径：勾选即保存（单键）
            Toggle("圆桌图片附件交给视觉模型识别", isOn: Binding(
                get: { vm.config?.visionParseAttachments ?? false },
                set: { vm.saveBool(SidecarConfig.Key.visionParseAttachments, $0) }))
                .toggleStyle(.checkbox)
                .padding(.top, 10)
                .accessibilityIdentifier("settings.visionParseToggle")
            HintText("开启后上传的图片附件会经视觉模型识别为文字参与讨论（需视觉模型）；关闭则图片仅作为材料标注。")

            Button {
                Task { await vm.saveExportSection() }
            } label: {
                Label("保存导出与附件设置", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.vPrimary)
            .padding(.top, 10)
            .accessibilityIdentifier("settings.saveExportButton")
        }
    }
}

// MARK: - 诊断（0.7.1 Bug 7：自 AboutPanel 平移——设置「关于」项撤除后的能力承接区）

/// 诊断小区块：原生运行时状态 / 数据根显示与修改 / 日志与数据根目录入口 / 调试 mock。
/// ⚠️ accessibilityIdentifier 全部保留 AboutPanel 原值（about.dataRootField /
/// about.openLogsButton / about.openDataRootButton / connectionStatusLabel /
/// mockAuthButton / mockAuthNetInstallButton）——冒烟脚本与测试按 id 引用。
private struct DiagnosticsSection: View {
    @EnvironmentObject private var appState: AppState
    /// 直接观察 NativeRuntime（@Published 绑定可写且状态实时；经 AppState 中转均不可）。
    @ObservedObject var runtime: NativeRuntime

    var body: some View {
        SectionCard(title: "诊断") {
            // ── 运行时状态（内核是进程内对象，init 同步建成即恒就绪）──
            HStack(spacing: 6) {
                Circle()
                    .fill(VTheme.ok)
                    .frame(width: 9, height: 9)
                Text(runtime.nativeReady ? "已就绪（原生内核）" : "初始化中")
                    .font(VTheme.Typo.caption)
                    .foregroundStyle(VTheme.textSecondary)
                    .accessibilityIdentifier("connectionStatusLabel")
                Spacer()
            }

            // ── 数据根（显示与修改；冒烟脚本 -sidecar.dataRoot 注入命根，键名不变）──
            FormLabel("数据根")
            TextField("VETARAI_DATA_ROOT", text: $runtime.dataRootPath)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("about.dataRootField")
            // 提示按生产口径写全内容与风险（tsx C1：核心数据不是缓存）
            HintText("应用数据根目录（默认 ~/.subagent，与 0.4.x 生产线同根）：项目与会话数据库、知识仓库索引与全局知识、已下载的模型、技能与插件、config.json 配置。修改将于下次启动生效。⚠️ 这里是核心数据不是缓存，删除会丢失项目、会话与知识库，请勿随意清理。")

            // ── 目录入口（AX id 保留 about.* 原值）──
            HStack(spacing: 10) {
                Button("打开日志目录") { appState.logger.openLogDirectory() }
                    .buttonStyle(.vSecondary)
                    .accessibilityIdentifier("about.openLogsButton")
                Button("打开数据根目录") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: appState.runtime.dataRootPath))
                }
                .buttonStyle(.vSecondary)
                .accessibilityIdentifier("about.openDataRootButton")
            }
            .padding(.top, 8)

            // ── 调试区（授权弹窗 mock；VETARAI_DEBUG_AUTH_MOCK=1 或 --debug-auth-mock）──
            if AuthCenter.debugMockEnabled {
                HStack(spacing: 10) {
                    Button("模拟授权请求（敏感删除）") { appState.auth.presentMock() }
                        .buttonStyle(.vSecondary)
                        .accessibilityIdentifier("mockAuthButton")
                    Button("模拟联网安装") { appState.auth.presentMock(netInstall: true) }
                        .buttonStyle(.vSecondary)
                        .accessibilityIdentifier("mockAuthNetInstallButton")
                }
                .padding(.top, 8)
            }
        }
    }
}
