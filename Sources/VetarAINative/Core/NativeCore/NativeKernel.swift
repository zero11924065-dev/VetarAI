//
//  NativeKernel.swift
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

//  NativeCore 各存储模块的聚合体（一个数据根一实例）：
//    · config   —— NativeConfigStore（config.json）
//    · database —— NativeDatabase（projects/_global.db 与 <pid>/agents.db）
//    · state    —— NativeStateStore（work/state.json）
//    · embedder —— NativeEmbedder（P2-W1：bge-m3 CoreML 嵌入，懒加载）
//    · knowledge—— NativeKnowledgeStore（P2-W1：知识仓库/知识库/记忆，接管
//      {data_root}/knowledge/index.db——与侧车同一库文件，schema 逐字兼容）
//
//  数据根绑定：内核与其影子的侧车必须读**同一个**数据根——历史上 SidecarManager
//  把 dataRootPath 作为 VETARAI_DATA_ROOT 传给侧车进程；P3-W6 侧车归零后由
//  NativeRuntime 持有同一数据根并构造本内核。内核经构造参数拿到该值，
//  注入 config store 的环境表，解析链（env > config.json > 默认）与 Python 完全一致。
//

import Foundation

public final class NativeKernel: @unchecked Sendable {

    /// 数据根（= 侧车 VETARAI_DATA_ROOT；CU 日志/技能目录等副作用的根）。
    public let dataRoot: URL
    public let config: NativeConfigStore
    public let database: NativeDatabase
    public let state: NativeStateStore
    public let embedder: NativeEmbedder
    public let knowledge: NativeKnowledgeStore
    /// P2-W2：工作流定义/运行记录持久化（接管 store.py L1103-1283 面）。
    public let workflow: NativeWorkflowStore
    /// P2-W2：取消事件 + 审批注册表（跨引擎实例共享，对应 engine.py 模块级字典）。
    public let workflowRuntime: NativeWorkflowRuntimeCenter
    /// P2-W3a：出站守卫（熔断器进程级，对齐 guard.py 模块全局 _circuit）。
    public let networkGuard: NativeNetworkGuard
    /// P2-W4a/d2：聊天运行时（cancel.py + inject.py 登记处；stop/inject 端点与
    /// chatStream 共用同一实例——一个数据根一份，对齐侧车模块级全局字典）。
    public let chatRuntime: NativeChatRuntimeCenter
    /// P2-W4d2：授权中心（_auth_pending + R2 授权记忆；chatStream 的 SSE 授权回调
    /// 与 respondAuth 端点共用）。
    public let authCenter: NativeAuthCenter
    public let log: (String) -> Void

    /// - Parameters:
    ///   - dataRoot: 数据根（= 侧车 VETARAI_DATA_ROOT；优先于 config.json 的 data_root 键）。
    ///   - modelDir: 嵌入模型目录覆盖（测试注入；生产 nil = 三级解析）。
    ///   - environment: 附加环境表（测试注入；真实进程 VETARAI_DATA_ROOT 通常不设，
    ///     由本参数承担侧车 launcher_prod.py 的等价角色）。
    public init(dataRoot: URL, modelDir: URL? = nil, log: @escaping (String) -> Void = { _ in }) {
        self.log = log
        self.dataRoot = dataRoot
        let store = NativeConfigStore(
            environment: ["VETARAI_DATA_ROOT": dataRoot.path],
            log: log)
        self.config = store
        // projects 根经 config 解析链产出（mkdir 副作用对齐 store.py L218-221）
        let projects = store.projectsRoot()
        self.database = NativeDatabase(projectsRoot: projects, log: log)
        self.state = NativeStateStore(projectsRoot: projects, log: log)
        // P2-W1：知识仓库 + CoreML 嵌入（同一数据根接管 index.db）
        self.embedder = NativeEmbedder(dataRoot: dataRoot, modelDir: modelDir, log: log)
        self.knowledge = NativeKnowledgeStore(dataRoot: dataRoot, database: database,
                                              embedder: embedder, log: log)
        // P2-W2：工作流内核（定义/运行存于同一 projects 根的全局库）
        self.workflow = NativeWorkflowStore(database: database, log: log)
        self.workflowRuntime = NativeWorkflowRuntimeCenter()
        // P2-W3a：出站守卫（配置经同一解析链；熔断触发写名单走 reloadConfig）
        self.networkGuard = NativeNetworkGuard(
            configProvider: { (try? store.getConfig()) ?? NativeConfigStore.defaultConfig },
            configWriter: { _ = try store.reloadConfig(patch: $0) },
            log: log)
        // P2-W4a/d2：聊天运行时 + 授权中心（进程级单例语义，对齐侧车模块全局）
        self.chatRuntime = NativeChatRuntimeCenter()
        self.authCenter = NativeAuthCenter(
            configProvider: { (try? store.getConfig()) ?? NativeConfigStore.defaultConfig },
            configWriter: { _ = try? store.reloadConfig(patch: $0) })
    }

    /// 混合路由表（结构化常量；设置页枚举展示用——经本访问器读，不散引）。
    public var routingEntries: [NativeRouteEntry] { NativeRoutingTable.entries }

    public func isNative(_ module: NativeModuleKind) -> Bool { NativeRoutingTable.isNative(module) }

    // ════════════════════════════════════════════════════════════
    // MARK: - P2-W4d2 chat 服务装配（懒加载：不开关/不调用零副作用）
    // ════════════════════════════════════════════════════════════

    /// 生产聊天连接器（Ollama /api/chat NDJSON；W4a）。
    public private(set) lazy var chatConnector = NativeOllamaChatConnector(config: config)

    /// REQ-FUT-020（0.7.5 W1）：.vmodel 安装注册表（全局平级清单/路由共用真源；
    /// 懒加载——不消费 .vmodel 零副作用）。
    /// H1 配套：禁用/移除条目时经 onEntryEvicted 回收路由单槽常驻引擎。
    public private(set) lazy var vmodelInstaller: NativeVModelInstaller = {
        let installer = NativeVModelInstaller(config: config)
        installer.onEntryEvicted = { dir in
            Task { await NativeVModelChatRouter.shared.unloadEngine(forModelDir: dir) }
        }
        // SDK 0.2.0（v2 容器密钥服务，契约 v1.5 §2.12/§3.3）装配点：
        // 生产密钥解析链 = SDK Keychain 缓存 + 登录态 tokenProvider 领取器
        // （baseURL 默认生产、UserDefaults licenseServerBaseURL 覆盖键）。
        // 首次安装 v2 容器时经 installer.keyResolver() 懒构造一次复用；
        // 领取成功写 Keychain 后离线可用。测试经同名缝注入内存缓存+mock。
        installer.keyResolverProvider = NativeVModelKeyAssembly.makeResolver
        return installer
    }()

    /// REQ-FUT-020（0.7.5 W1）：委派/圆桌共享的 .vmodel 路由连接器
    /// （"vmodel:<slug>" 走 NativeVModelChatRouter MLX 推理，其余透传 ollama 底座）。
    public private(set) lazy var vmodelRoutingConnector = NativeVModelRoutingConnector(
        base: chatConnector, installer: vmodelInstaller)

    /// P3-W2b：OpenAI 兼容后端聊天连接器（openai_compat.py 逐行为；chatStream 分流
    /// 见 NativeSidecarClient——懒加载：不开关/不调用零副作用）。
    public private(set) lazy var openAIChatConnector = NativeOpenAIChatConnector(
        config: config, guard: networkGuard)

    /// 技能管理器（skills_mgr 移植，W4c；loop 的 read_skill 路由经 NativeSkillReader 适配）。
    public private(set) lazy var skillsManager = NativeSkillsManager(dataRoot: dataRoot)

    /// 知识检索适配器（search_knowledge 路由面；warehouse.search_scoped）。
    public private(set) lazy var knowledgeSearcher: any NativeKnowledgeSearcher =
        NativeKernelKnowledgeSearcher(store: knowledge)

    /// 单元归档执行器（archive_work_unit 路由，W4c）。
    public private(set) lazy var archiveExecutor = NativeWorkUnitArchiveExecutor(
        database: database, knowledge: knowledge)

    /// 委派执行器（W4b 内核；生产装配：live 工具上下文 + 知识/记忆/技能注入 provider
    /// + /api/tags 模型名单）。0.7.4 W11：偏差③两处缺口已接管——
    ///   · safeUnloadModel = NativeWorkflowHTTPConnector.unloadModel（ollama
    ///     keep_alive:0 空消息 / openai no-op true / 失败静默 false——正是
    ///     Python safe_unload_model 的「safe」语义）；
    ///   · visionProbe = /api/show capabilities 探测（非 ollama 后端 → true 放行；
    ///     键缺失/非 200/异常 → true 不阻塞，对齐 modelSupportsVision 降级口径）。
    public private(set) lazy var delegationEngine = NativeDelegationEngine(
        db: database, connector: vmodelRoutingConnector,
        // 0.7.8 实测 Bug4：委派子会话必须挂授权通道——此前缺省 nil，子 agent
        // 写敏感路径直接吃「当前无授权通道」拒绝（NativeToolRegistry L352 分支），
        // 交卷只能是失败。挂进程级 authCenter 后：子会话请求经主流 gen() 心跳
        // drainUnsent 冒泡主 UI 弹窗（委派期间主流阻塞在 delegate_task 但心跳
        // 照常唤醒）；R2 授权记忆 isGranted 命中即放行，白拿主会话已授权记忆；
        // 主流停止时 cleanup() 的 auth.failAll() 保证挂起请求安全拒绝。
        // workflow 引擎刻意 authorizer=nil 的语义不受影响（独立装配面）。
        authorizer: authCenter.makeAuthorizer(),
        toolContext: .live(config: config, guard: networkGuard),
        configProvider: { [config] in
            (try? config.getConfig()) ?? NativeConfigStore.defaultConfig
        },
        listModels: { [config] in
            // REQ-FUT-020（0.7.5 W1）：.vmodel 平级入可用名单——model_override
            // 指定 "vmodel:<slug>" 通过存在性校验，可由委派引擎真分派。
            await NativeChatEndpointAssembly.fetchOllamaModelNames(
                config: (try? config.getConfig()) ?? NativeConfigStore.defaultConfig)
                + NativeVModelParity.poolNames(
                    forEnabledIn: NativeVModelInstaller(config: config).listInstalled())
        },
        visionProbe: { [config] model in
            let cfg = (try? config.getConfig()) ?? NativeConfigStore.defaultConfig
            // 非 ollama 后端无 /api/show 探测面 → 放行（不阻塞委派）
            guard NativeInferenceEndpointAssembly.backendStripped(cfg) == "ollama"
            else { return true }
            return await NativeInferenceEndpointAssembly.liveOllamaShowSupportsVision(
                NativeInferenceEndpointAssembly.ollamaBase(cfg), model)
        },
        safeUnloadModel: { [config] model in
            await NativeWorkflowHTTPConnector(config: config).unloadModel(model)
        },
        knowledgeTextProvider: { [knowledge] pid in knowledge.buildKnowledgeText(pid) },
        memoryInjectionProvider: { [knowledge] pid in knowledge.buildMemoryInjection(pid) },
        skillsListTextProvider: { [skillsManager] in skillsManager.buildSkillsListText() })

    /// 圆桌执行引擎（W4d1 内核）。REQ-FUT-020：connector 经 .vmodel 路由——
    /// 角色 Agent 的 model_name 为 "vmodel:<slug>" 时走 MLX 推理真路径。
    /// 0.7.7 W6：vmodel 发言经 vmodelAgenticRunner 升级为工具调用回路
    /// （降级口径与埋点见 NativeVModelAgentic 文件头）。
    public private(set) lazy var roundtableEngine = NativeRoundtableEngine(
        db: database, connector: vmodelRoutingConnector,
        configProvider: { [config] in
            (try? config.getConfig()) ?? NativeConfigStore.defaultConfig
        },
        vmodelAgentic: vmodelAgenticRunner)

    /// 0.7.7 W6：面板侧 vmodel agentic 观测汇流——与工作室会话同一 metrics/
    /// 目录、同一 StudioMetricsSink/JSONL 格式（三层观测的执行层），sessionID
    /// 固定 "vmodel-agentic"（圆桌/工作流非工作室会话，无会话 sink 可挂；
    /// 固定归属绝不串记到别的工作室会话名下）。
    public private(set) lazy var studioPanelMetricsSink = StudioMetricsSink(
        directory: dataRoot.appendingPathComponent("studio/metrics", isDirectory: true),
        sessionID: "vmodel-agentic")

    /// 0.7.7 W6：圆桌/工作流共用的 vmodel agentic 执行器——复用委派同款
    /// runToolLoop 全回路 + 主会话同一工具注册表口径（.live 上下文 +
    /// search_knowledge + read_skill；不委派不联网安装，F2 纪律）。
    public private(set) lazy var vmodelAgenticRunner: NativeVModelAgenticFn =
        makeVModelAgenticRunner(metricsSink: studioPanelMetricsSink)

    /// agentic 执行器工厂（埋点汇流可按调用面换绑：圆桌/工作流面板 =
    /// studioPanelMetricsSink 固定归属；工作室 discuss = 会话级 sink，
    /// 与该会话 llm.done/kv 埋点同流）。
    public func makeVModelAgenticRunner(metricsSink: StudioMetricsSink?) -> NativeVModelAgenticFn {
        let conn = vmodelRoutingConnector
        let installer = vmodelInstaller
        let cfg = config
        let netGuard = networkGuard
        let searcher = knowledgeSearcher
        let skills = skillsManager
        return { req in
            try await NativeVModelAgentic.run(
                request: req,
                toolSupportProbe: {
                    NativeVModelAgentic.vmodelSupportsToolCalls(poolName: $0,
                                                                installer: installer)
                },
                connector: conn,
                toolContext: .live(config: cfg, guard: netGuard),
                knowledgeCtx: NativeKnowledgeContext(projectId: req.projectId,
                                                     searcher: searcher),
                skillReader: skills,
                configProvider: { (try? cfg.getConfig()) ?? NativeConfigStore.defaultConfig },
                metricsSink: metricsSink)
        }
    }

    /// 应用内模块控制注册表（W4c；roundtable 动作经真引擎驱动）。
    public private(set) lazy var appModuleRegistry = NativeAppModuleRegistry(
        workflowStore: workflow,
        knowledge: knowledge,
        workflowRuntime: workflowRuntime,
        connector: NativeWorkflowHTTPConnector(config: config),
        roundtableCreator: NativeKernelRoundtableCreator(engine: roundtableEngine),
        vmodelAgentic: vmodelAgenticRunner)

    /// Computer Use 执行引擎（W4c；懒加载——computer_use_enabled 开关不开则不触达，
    /// 对齐 Python 的零副作用口径）。
    public private(set) lazy var computerUseEngine = NativeComputerUseEngine(
        adapter: NativeCoreGraphicsCUAdapter(),
        dataRoot: dataRoot,
        configProvider: { [config] in
            (try? config.getConfig()) ?? NativeConfigStore.defaultConfig
        })

    /// chat 端点装配体（api_ollama_chat_stream / stop / inject / auth respond）。
    public private(set) lazy var chatEndpoints = NativeChatEndpointAssembly(kernel: self)

    /// P3-W2a：懒加载档位表内核级共享实例（对齐 infer_options 模块级 _CTX_LAZY_STATE
    /// 的进程级语义）。⚠️ W4a 偏差②不动：NativeChatEndpoints.gen() 仍每流自建实例——
    /// 本实例当前服务 context/limit 端点（报起始档与原生 chat 下一次注入值同口径）。
    public private(set) lazy var lazyCtxTiers = NativeLazyCtxTiers(configProvider: { [config] in
        (try? config.getConfig()) ?? NativeConfigStore.defaultConfig
    })

    /// P3-W2a：推理面板端点装配体（status/models/pull/delete/context-limit；
    /// P3-W3a：MP 三分支缝接 llamaDriver/mpChatConnector/modelPackStore）。
    public private(set) lazy var inferenceEndpoints: NativeInferenceEndpointAssembly = {
        let assembly = NativeInferenceEndpointAssembly(config: config, tiers: lazyCtxTiers)
        assembly.mpActiveBaseURL = { [llamaDriver] in llamaDriver.activeBaseURL() }
        assembly.mpListModels = { [mpChatConnector] in mpChatConnector.listModels() }
        // REQ-FUT-020 0.7.5 工程遗留③ / W3：modelsMP 退化面并 .vmodel 启用集
        // （与 vmodelUnionFetcher 同真源，注册表直读无副作用）。
        assembly.mpVModelUnion = { [vmodelInstaller] in
            NativeVModelParity.inferenceEntries(forEnabledIn: vmodelInstaller.listInstalled())
        }
        assembly.mpManifestContextLength = { [modelPackStore] pid in
            guard case .int(let n) = modelPackStore.readManifest(pid)["context_length"],
                  n > 0 else { return nil }
            return Int(n)
        }
        return assembly
    }()

    // ════════════════════════════════════════════════════════════
    // MARK: - P3-W3a 模型包装配（懒加载：不开面板/不对话零副作用）
    // ════════════════════════════════════════════════════════════

    /// 模型包安装根注册表（store.py 移植①）。
    public private(set) lazy var modelPackStore = NativeModelPackStore(
        configProvider: { [config] in
            (try? config.getConfig()) ?? NativeConfigStore.defaultConfig
        },
        dataRootProvider: { [dataRoot] in dataRoot },
        environment: ProcessInfo.processInfo.environment)

    /// 模型包下载器（downloader.py 移植②；生命周期事件默认上原生总线）。
    public private(set) lazy var modelPackDownloader = NativeModelPackDownloader(
        store: modelPackStore, networkGuard: networkGuard)

    /// 下载任务注册表（每 pack_id 至多一个任务）。
    public private(set) lazy var modelPackDownloadManager = NativeModelPackDownloadManager(
        downloader: modelPackDownloader)

    /// llama-server 驱动（llamacpp_driver.py 移植③）。
    public private(set) lazy var llamaDriver = NativeLlamaCppDriver(
        store: modelPackStore,
        environment: ProcessInfo.processInfo.environment,
        dataRootProvider: { [dataRoot] in dataRoot },
        configProvider: { [config] in
            (try? config.getConfig()) ?? NativeConfigStore.defaultConfig
        })

    /// MP 后端聊天连接器（mp_connector.py 移植④；tiers 共享内核档位表——
    /// loop bump 与驱动异档重启同一份档位状态，Python 模块级 _CTX_LAZY_STATE 同款）。
    /// 0.7.7 W3：注入 MLX 支路连接器（driver=mlxswift 包分派进程内 mlx-swift-lm
    /// 推理；mpMLXChatConnector 不回指本连接器，懒构造无环）。
    public private(set) lazy var mpChatConnector: NativeMPChatConnector = {
        let conn = NativeMPChatConnector(
            driver: llamaDriver, store: modelPackStore, tiers: lazyCtxTiers,
            configProvider: { [config] in
                (try? config.getConfig()) ?? NativeConfigStore.defaultConfig
            },
            guard: networkGuard, transport: NativeURLSessionOpenAITransport())
        conn.mlxConnector = mpMLXChatConnector
        return conn
    }()

    /// 0.7.7 W3：MLX 模型包驱动（魔塔 MLX 仓选中装载；引擎单槽常驻，
    /// driver=mlxswift 包的推理出口）。懒加载——不选中 MLX 包零副作用。
    public private(set) lazy var mpMLXDriver = NativeMPMLXDriver(store: modelPackStore)

    /// 0.7.7 W3：MLX 模型包聊天连接器（tiers 共享内核档位表，与 llama 支路同款）。
    public private(set) lazy var mpMLXChatConnector = NativeMPMLXChatConnector(
        driver: mpMLXDriver, tiers: lazyCtxTiers)

    /// 路由换装编排（routing.py 移植④；chatStream MP 分流用）。
    public private(set) lazy var modelPackRouter = NativeModelPackRouter(
        store: modelPackStore, driver: llamaDriver,
        configProvider: { [config] in
            (try? config.getConfig()) ?? NativeConfigStore.defaultConfig
        })

    /// /api/model-packs 六端点装配体（app.py L2746-2900 移植⑤）。
    /// P3-W3b：asrDriver 注入——卸载/禁用回收 ASR onnx session（L2774-2778 同构）。
    /// 0.7.7 W3：mlxDriver 注入——卸载/禁用 driver=mlxswift 包回收进程内 MLX 引擎。
    public private(set) lazy var modelPackEndpoints: NativeModelPackEndpoints = {
        let endpoints = NativeModelPackEndpoints(
            store: modelPackStore, downloader: modelPackDownloader,
            manager: modelPackDownloadManager, driver: llamaDriver,
            configProvider: { [config] in
                (try? config.getConfig()) ?? NativeConfigStore.defaultConfig
            })
        endpoints.asrDriver = asrDriver
        endpoints.mlxDriver = mpMLXDriver
        return endpoints
    }()

    // ════════════════════════════════════════════════════════════
    // MARK: - P3-W3b ASR 装配（懒加载：不点话筒/不查状态零副作用——
    //   首次转写才 dlopen onnxruntime + 建 onnx session）
    // ════════════════════════════════════════════════════════════

    /// ASR 驱动（asr_driver.py 移植⑥；会话按 pack_id 键控懒加载，换包重载）。
    public private(set) lazy var asrDriver = NativeAsrDriver(
        store: modelPackStore,
        environment: ProcessInfo.processInfo.environment,
        dataRootProvider: { [dataRoot] in dataRoot })

    /// /api/asr/* 两端点装配体（app.py L2917-3027 移植⑦；status 永不 5xx +
    /// transcribe 400 校验链/409/422 + C7 落盘归属）。
    public private(set) lazy var asrEndpoints = NativeAsrEndpoints(
        store: modelPackStore, driver: asrDriver,
        projectsRootProvider: { [config] in config.projectsRoot() })

    // ════════════════════════════════════════════════════════════
    // MARK: - P3-W4 CU 宏装配（懒加载：不开面板/不用 CU 零副作用——
    //   首次 user 录制才建 CGEventTap）
    // ════════════════════════════════════════════════════════════

    /// /api/cu-macros* 八端点装配体（app.py L2453-2552 移植⑧）+ user 模式捕获缝
    /// 生产接线（「输入监控」TCC 主体 = 原生 app 自身；hit 探针与 CU 引擎同源）。
    public private(set) lazy var cuMacroEndpoints: NativeCUMacroEndpoints = {
        let store = computerUseEngine.macroStore
        store.listenAccessGrantedProvider = { NativeUserRecorder.listenAccessGranted() }
        store.maxSecondsProvider = { [config] in
            let cfg = (try? config.getConfig()) ?? NativeConfigStore.defaultConfig
            // cfg.get("cu_user_record_max_seconds", 600)（读不到 → 600；
            // `or 600` 的 0→600 兜底在 store 层，对齐 cu_macro.py L258 归属）
            return cfg["cu_user_record_max_seconds"].flatMap(PySem.toFloat) ?? 600.0
        }
        store.userCaptureFactory = { [weak self] onStep, onTimeout, maxS in
            guard let self else { return nil }
            let adapter = self.computerUseEngine.platformAdapter
            return NativeUserRecorder.startCapture(
                onStep: onStep, onTimeout: onTimeout, maxSeconds: maxS,
                probes: .system(hit: { adapter.hitTest(x: $0, y: $1) }))
        }
        store.replayStepEventPusher = { runId, macroId, seq, action, method, ok in
            // _push_step_event（cu_macro.py L428-442）：⚠️ 步骤的 CU 动作名只能放
            // step_action（notify 第二位置参数就叫 action，Python 实测踩中）
            NativeEndpointNotify.change(NativeAppEvents.resourceCuMacro, "replay_step",
                extra: ["run_id": .string(runId), "macro_id": .string(macroId),
                        "seq": .int(Int64(seq)), "step_action": .string(action),
                        "method": .string(method), "ok": .bool(ok)])
        }
        return NativeCUMacroEndpoints(store: store)
    }()

    // ════════════════════════════════════════════════════════════
    // MARK: - P3-W5 插件装配（懒加载：不开面板/不触发 hook 零副作用——
    //   首次 hook 触发才落 shim + 起 python3 子进程）
    // ════════════════════════════════════════════════════════════

    /// 插件管理面存储（loader.py L49-305 移植⑨：state/notes 两 JSON + 列表/卸载/
    /// 开关 + hook 模块解析）。与侧车同一 PLUGINS_ROOT 语义（dataRoot/plugins）。
    public private(set) lazy var pluginStore = NativePluginStore(pluginsRoot: config.pluginsRoot())

    /// 插件 install 工具上下文（NativeToolInstall.installPlugin 通道：git clone
    /// 过守卫 + 熔断上报 + 剥代理环境 + 120s——P2-W3a 既有实现复用）。
    public private(set) lazy var pluginInstallContext = NativeToolContext.live(
        config: config, guard: networkGuard)

    /// /api/plugins* 八端点装配体（app.py L844-913 移植⑩；hook 执行经 ADR-0046
    /// P-A python3 子进程桥——生产 NativePluginHookRunner.system）。
    public private(set) lazy var pluginEndpoints = NativePluginEndpoints(
        store: pluginStore, installContext: pluginInstallContext)
}

// ════════════════════════════════════════════════════════════
// MARK: - 内核装配适配器（W4d2）
// ════════════════════════════════════════════════════════════

/// NativeKnowledgeStore → NativeKnowledgeSearcher 适配（search_scoped 逐字段映射）。
public struct NativeKernelKnowledgeSearcher: NativeKnowledgeSearcher {
    public let store: NativeKnowledgeStore
    public init(store: NativeKnowledgeStore) { self.store = store }
    public func searchScoped(_ query: String, scope: String, projectId: String?,
                             limit: Int, mode: String) -> [NativeKnowledgeSearchHit] {
        store.searchScoped(query, scope: scope, projectId: projectId,
                           limit: limit, mode: mode).map {
            NativeKnowledgeSearchHit(title: $0.title, scope: $0.scope,
                                     score: $0.score, body: $0.body ?? "")
        }
    }
}

/// NativeRoundtableEngine → NativeRoundtableCreator 适配（app_control 的圆桌创建动作）。
/// 返回形态逐字对齐 registry.py `_roundtable_create`：
/// 成功 {"ok": True, "roundtable": rt, "note": "…"}；失败 {"ok": False, "error": "roundtable_create_failed: …"}。
public struct NativeKernelRoundtableCreator: NativeRoundtableCreator {
    public let engine: NativeRoundtableEngine
    public init(engine: NativeRoundtableEngine) { self.engine = engine }
    public func createRoundtable(projectId: String, topic: String, agentIds: [String],
                                 moderator: String, moderatorAgentId: String?,
                                 maxRounds: Int) async -> [String: JSONValue] {
        do {
            let row = try await engine.createAndStart(
                projectId: projectId, topic: topic, agentIds: agentIds,
                moderator: moderator, moderatorAgentId: moderatorAgentId,
                maxRounds: maxRounds)
            return ["ok": .bool(true), "roundtable": .object(Self.rowJSON(row)),
                    "note": .string("圆桌已创建并完成第一轮。后续轮次由用户在圆桌面板继续（结束权在用户）。")]
        } catch let e as NativeRoundtableError {
            return ["ok": .bool(false), "error": .string("roundtable_create_failed: \(e.message)")]
        } catch {
            return ["ok": .bool(false),
                    "error": .string("roundtable_create_failed: \(String(describing: error))")]
        }
    }

    /// create_and_start 返回 dict 的同构映射（store.py 列 → JSON）。
    static func rowJSON(_ r: NativeRoundtableRow) -> [String: JSONValue] {
        [
            "id": .string(r.id), "project_id": .string(r.projectId), "topic": .string(r.topic),
            "participants": .array(r.participants.map { .object($0) }),
            "moderator": .string(r.moderator),
            "moderator_agent_id": r.moderatorAgentId.map { .string($0) } ?? .null,
            "max_rounds": .int(Int64(r.maxRounds)), "round": .int(Int64(r.round)),
            "status": .string(r.status),
            "minutes": r.minutes.map { .string($0) } ?? .null,
            "summary": r.summary.map { .string($0) } ?? .null,
            "created_at": r.createdAt.map { .string($0) } ?? .null,
            "updated_at": r.updatedAt.map { .string($0) } ?? .null,
            "attachments": .array(r.attachments.map { .object($0) }),
        ]
    }
}
