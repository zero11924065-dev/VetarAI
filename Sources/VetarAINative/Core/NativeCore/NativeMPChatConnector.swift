//
//  NativeMPChatConnector.swift
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

//  逐行为移植（⛔ 只读行为规格源：
//    subagent/sidecar/model_packs/mp_connector.py，127 行；
//    subagent/sidecar/ollama/routing.py 换装编排部分 L100-162 + agent_engine/
//    loop.py:153-177 safe_unload_model）：
//    · 协议零改动复用 NativeOpenAIChatConnector（SSE 分块/工具拼装/异常语义
//      一字不动——协议一致是审核一票否决项），只换三件事：base_url 来源=
//      驱动动态端口 / 生命周期前置 ensure / 模型清单=注册表聚合
//    · _ensure_running（L64-76）：tier=infer_options.current_ctx_for(model,
//      "model_package") 显式 backend 参 → driver.ensure_server；LlamaServerError
//      → OllamaAPIError(str(e), 400, "") 等价 NativeChatConnectorError.openAI
//    · _base（L50-56）：活动地址空 → 「模型包服务未在运行…」逐字 400
//    · list_models（L93-105）：已安装且启用 chat 包（name=pack_id/size=磁盘
//      实际字节/source="model_pack"/context_length 真值才带）；capabilities
//      （L107-116）tools 真 vision/pull/delete 假；unload_model=stop_server；
//      list_loaded=[active_pack] 或 []
//    · 路由编排（routing.py）：degraded=backend==model_package 全走 MP；
//      _is_chat_pack 注册表 task==chat 且（any_status 或 status==installed）；
//      方向①命中包→preSwapToPack 卸活动后端驻留（safe_unload 双防护复刻）；
//      方向②命中活动后端→preSwapToActive 停 llama-server（失败记日志不阻断）
//
//  偏差（汇报清单同步）：
//    ① model_options 注入走 NativeWorkflowHTTPConnector.paramMapOpenAI（非
//       ollama 后端同表）：Python _INFER_BACKEND="model_package" 复用 openai
//       映射行（num_ctx 丢弃），两侧同表等价，无需分支。
//    ② base 预检与内层 configProvider overlay 读取之间存在理论竞态（ensure
//       成功后进程恰死 → 内层报「推理后端地址未配置」而非「模型包服务未在
//       运行」）；Python _base() 同样两次读 active_base_url()，窗口同构。
//    ③ 方向③（workflow/delegation 面 unload_model 双向分发 + list_loaded
//       并集）未接：NativeWorkflowHTTPConnector.unloadModel 的 model_package
//       分支仍返回 false（P3-W2 路由表已注「model_package 后端未接管」，
//       刻意留待后续波次）。
//

import Foundation

// ════════════════════════════════════════════════════════════
// MARK: - MP 连接器（mp_connector.py 逐行为）
// ════════════════════════════════════════════════════════════

public final class NativeMPChatConnector: NativeChatConnector, @unchecked Sendable {

    public let driver: NativeLlamaCppDriver
    public let store: NativeModelPackStore
    public let tiers: NativeLazyCtxTiers
    /// 协议层（openai_compat 一字不动）：config overlay 指向驱动动态端口。
    private let inner: NativeOpenAIChatConnector

    public init(driver: NativeLlamaCppDriver,
                store: NativeModelPackStore,
                tiers: NativeLazyCtxTiers,
                configProvider: @escaping @Sendable () -> [String: JSONValue],
                guard networkGuard: NativeNetworkGuard,
                transport: any NativeOpenAITransport) {
        self.driver = driver
        self.store = store
        self.tiers = tiers
        // ① 连接基础：地址来自驱动（动态端口），不读 config inference_base_url；
        // 回环无密钥（inference_api_key 置空，防真配置里的 key 泄给本机进程）。
        let overlay: @Sendable () -> [String: JSONValue] = {
            var cfg = configProvider()
            cfg["inference_base_url"] = .string(driver.activeBaseURL() ?? "")
            cfg["inference_api_key"] = .string("")
            return cfg
        }
        self.inner = NativeOpenAIChatConnector(configProvider: overlay,
                                               guard: networkGuard, transport: transport)
    }

    /// 0.7.7 W3：MLX 模型包支路连接器（注册表 driver=mlxswift 的 chat 包走
    /// mlx-swift-lm 进程内推理；生产由 NativeKernel 装配注入）。nil 而遇 MLX 包
    /// → 诚实报错——绝不静默落 llama 支路（那边只会报「没有 .gguf 权重」误导）。
    public var mlxConnector: NativeMPMLXChatConnector? = nil

    /// 0.7.7 W3：注册表驱动键判定（mlxswift = 魔塔 MLX 仓等；缺省/其余 →
    /// llama 支路原口径零改动）。
    func isMLXPack(_ model: String) -> Bool {
        store.getEntry(model)?["driver"]?.string == "mlxswift"
    }

    /// MLX 支路出口（0.7.7 W3）：起手先停 llama-server 还内存（换装对称①，
    /// best-effort 与 preSwapToActive 同纪律），再交本支路连接器真流。
    private func mlxChatStream(model: String, messages: [[String: JSONValue]],
                               tools: [JSONValue]?)
        -> AsyncThrowingStream<NativeChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let mlx = self.mlxConnector else {
                        throw NativeChatConnectorError.openAI(
                            status: 400,
                            message: "该模型包为 MLX 格式，但本机 MLX 推理驱动未装配（请升级应用）",
                            detail: "")
                    }
                    _ = await self.driver.stopServer()   // 换装对称①（还统一内存）
                    for try await ev in mlx.chatStream(model: model, messages: messages,
                                                       tools: tools, images: nil) {
                        continuation.yield(ev)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    /// _base（L50-56）：活动地址空 → 逐字文案 400。
    private func baseURLOrThrow() throws -> String {
        guard let url = driver.activeBaseURL() else {
            throw NativeChatConnectorError.openAI(
                status: 400,
                message: "模型包服务未在运行（对话时会自动启动；看到本条多半意味着启动刚失败），"
                    + "请到「模型包」面板确认目标包已安装并启用",
                detail: "")
        }
        return url
    }

    /// _ensure_running（L64-76）：对话前确保目标包在跑（换装/异档判定全在驱动锁内，
    /// 本层只传期望值——竞态防线，与 routing 换装编排同一纪律）。
    private func ensureRunning(_ model: String) async throws {
        let tier = tiers.currentCtxFor(model, backend: "model_package")
        do {
            _ = try await driver.ensureServer(model, contextLength: tier)
        } catch let e as NativeLlamaServerError {
            throw NativeChatConnectorError.openAI(status: 400, message: e.message, detail: "")
        }
        _ = try baseURLOrThrow()   // ensure 成功但地址已空（进程恰死）→ 逐字 400
    }

    /// chat_stream（L85-90）：ensure 在流首次消费时执行（Python async gen 同款惰性）。
    /// 0.7.7 W3：driver=mlxswift 的包分派 MLX 支路（进程内 mlx-swift-lm 推理）；
    /// GGUF 支路起手先卸 MLX 驻留引擎（换装对称②，best-effort 不阻断）。
    public func chatStream(model: String, messages: [[String: JSONValue]],
                           tools: [JSONValue]?, images: [String]?)
        -> AsyncThrowingStream<NativeChatStreamEvent, Error> {
        if isMLXPack(model) {
            return mlxChatStream(model: model, messages: messages, tools: tools)
        }
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    if let mlx = self.mlxConnector { await mlx.unloadActive() }   // 换装对称②
                    try await ensureRunning(model)
                    let inner2 = self.inner
                    for try await ev in inner2.chatStream(model: model, messages: messages,
                                                          tools: tools, images: images) {
                        continuation.yield(ev)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    /// chat（L78-83）非流式（报错分析模型用）。0.7.7 W3：MLX 支路同款分派。
    public func chat(model: String, messages: [[String: JSONValue]]) async throws -> String {
        if isMLXPack(model) {
            guard let mlx = mlxConnector else {
                throw NativeChatConnectorError.openAI(
                    status: 400,
                    message: "该模型包为 MLX 格式，但本机 MLX 推理驱动未装配（请升级应用）",
                    detail: "")
            }
            _ = await driver.stopServer()   // 换装对称①
            return try await mlx.chat(model: model, messages: messages)
        }
        if let mlx = mlxConnector { await mlx.unloadActive() }   // 换装对称②
        try await ensureRunning(model)
        return try await inner.chat(model: model, messages: messages)
    }

    // MARK: - ③ 模型清单：注册表聚合（不问 llama-server /v1/models）

    /// list_models（L93-105）：已安装且启用的 chat 任务包；asr/embedding 与
    /// 已禁用包不出现。
    public func listModels() -> [[String: JSONValue]] {
        store.listInstalled().compactMap { p in
            guard p["task"]?.string == "chat", p["enabled"]?.bool == true,
                  let packId = p["pack_id"]?.string else { return nil }
            var entry: [String: JSONValue] = [
                "name": .string(packId),
                "size": .int(p["size_bytes"].flatMap(PySem.toFloat).map { Int64($0) } ?? 0),
                "source": .string("model_pack"),
            ]
            if let cl = p["context_length"].flatMap(PySem.toFloat), cl > 0 {
                entry["context_length"] = .int(Int64(cl))
            }
            return entry
        }
    }

    /// capabilities（L107-116）：端点守卫与前端渲染的唯一事实源。
    public func capabilities() -> [String: JSONValue] {
        ["backend": .string("model_package"), "tools": .bool(true),
         "vision": .bool(false), "pull": .bool(false), "delete": .bool(false)]
    }

    // MARK: - 生命周期覆盖：父类 no-op → 真实的停子进程

    /// unload_model（L119-121）：停止活动 llama-server 子进程。
    /// 0.7.7 W3：MLX 包改卸进程内 MLX 驻留引擎（名字匹配防护在驱动层）。
    public func unloadModel(_ name: String) async -> Bool {
        if isMLXPack(name) { return await mlxConnector?.unload(name) ?? false }
        return await driver.stopServer(name)
    }

    /// list_loaded_models（L123-127）：活动包列表（0 或 1 个）——与 Ollama
    /// /api/ps 的「确在内存再卸」防护同构。
    /// ⚠️ 0.7.7 W3 偏差登记：本面只回 llama 支路活动包；MLX 驻留引擎为 actor
    /// 态（本方法同步协议拿不到）。影响面为零——工作流 unload 的
    /// model_package 分支本批次前即未接（本文件偏差③），唯一直达 unload 的
    /// unloadModel 已按 driver 键正确分派。
    public func listLoadedModels() -> [String] {
        driver.activePack().map { [$0] } ?? []
    }
}

// ════════════════════════════════════════════════════════════
// MARK: - 路由换装编排（routing.py L95-162 + loop.py safe_unload_model）
// ════════════════════════════════════════════════════════════

/// 按 model 名归边的路由判定与跨引擎内存编排（无内部状态：后端按 config
/// 每次调用动态解析，与 Python RoutingConnector 同款哲学）。
public final class NativeModelPackRouter: @unchecked Sendable {

    /// safe_unload_model 双防护超时默认（loop.py L59-60）；实例可收窄（Python
    /// 测试 monkeypatch 模块常量同款意图——杀进程路径不值得每次真等 20s）。
    public static let swapTimeoutDefault = 20.0
    public static let swapPSTimeoutDefault = 8.0
    public var swapTimeout = NativeModelPackRouter.swapTimeoutDefault
    public var swapPSTimeout = NativeModelPackRouter.swapPSTimeoutDefault

    public let store: NativeModelPackStore
    public let driver: NativeLlamaCppDriver
    public var configProvider: @Sendable () -> [String: JSONValue]
    /// 活动后端 list_loaded_models 缝：ollama → GET /api/ps 名单；openai → 空
    /// （openai_compat.list_loaded_models no-op 空列表，天然跳过）。
    public var activeLoadedModels: @Sendable () async throws -> [String]
    /// 活动后端 unload_model 缝：ollama → POST /api/chat keep_alive:0；
    /// openai → 恒 true no-op。
    public var activeUnload: @Sendable (String) async throws -> Bool
    public var log: @Sendable (String) -> Void = { _ in }

    public init(store: NativeModelPackStore,
                driver: NativeLlamaCppDriver,
                configProvider: @escaping @Sendable () -> [String: JSONValue],
                activeLoadedModels: (@Sendable () async throws -> [String])? = nil,
                activeUnload: (@Sendable (String) async throws -> Bool)? = nil) {
        self.store = store
        self.driver = driver
        self.configProvider = configProvider
        // 生产默认：按 config 动态分派 ollama/openai（routing.py _active() 同款）
        self.activeLoadedModels = activeLoadedModels ?? {
            let cfg = configProvider()
            guard Self.backendStripped(cfg) != "openai_compatible" else { return [] }
            let base = Self.ollamaBase(cfg)
            let models = try await NativeInferenceEndpointAssembly.liveOllamaPS(base)
            return models.compactMap { $0["name"]?.string }
        }
        self.activeUnload = activeUnload ?? { name in
            let cfg = configProvider()
            guard Self.backendStripped(cfg) != "openai_compatible" else { return true }
            return try await Self.liveOllamaUnload(base: Self.ollamaBase(cfg), model: name)
        }
    }

    /// routing.py _backend()（L73-75）：strip，不小写（退化判定逐字相等）。
    public static func backendStripped(_ cfg: [String: JSONValue]) -> String {
        (cfg["inference_backend"]?.string ?? "ollama")
            .trimmingCharacters(in: .whitespaces)
    }

    static func ollamaBase(_ cfg: [String: JSONValue]) -> String {
        (cfg["ollama_base_url"]?.string ?? "http://localhost:11434")
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
    }

    /// ollama unload_model（connector.py L432-447）：keep_alive:0 空消息。
    static func liveOllamaUnload(base: String, model: String) async throws -> Bool {
        guard let url = URL(string: "\(base)/api/chat") else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = NativeModelPackRouter.swapTimeoutDefault
        let payload: [String: JSONValue] = [
            "model": .string(model), "messages": .array([]),
            "stream": .bool(false), "keep_alive": .int(0),
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: payload.mapValues { $0.anyValue })
        let (_, resp) = try await URLSession.shared.data(for: req)
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }

    // MARK: - 路由判定

    /// _degraded（L95-97）：model_package 旧配置 → 路由退化为全走 MP。
    public func degraded() -> Bool {
        Self.backendStripped(configProvider()) == "model_package"
    }

    /// _is_chat_pack（L100-116）：model 命中已安装 chat 包。any_status=false 须
    /// 启用中；true 含已禁用（卸载路由——禁用后进程若仍在必须把内存还回来）。
    public func isChatPack(_ model: String, anyStatus: Bool = false) -> Bool {
        guard !model.isEmpty, let entry = store.getEntry(model) else { return false }
        guard entry["task"]?.string == "chat" else { return false }
        return anyStatus || entry["status"]?.string == "installed"
    }

    /// _route_to_pack（L118-121）。
    public func routeToPack(_ model: String) -> Bool {
        degraded() || isChatPack(model)
    }

    // MARK: - safe_unload_model（loop.py L153-177 逐行为）

    /// asyncio.wait_for 等价：超时返回 nil（操作取消）。
    static func withTimeout<T: Sendable>(_ seconds: Double,
                                         _ op: @Sendable @escaping () async throws -> T)
        async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { try? await op() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// 防护①卸载与查 ps 各自独立超时；防护②先查 ps 确在内存再卸（兼容带 tag：
    /// x==model 或 x.split(":")[0]==model.split(":")[0]）；任何失败静默 False。
    public func safeUnload(_ model: String) async -> Bool {
        guard !model.isEmpty else { return false }
        let loaded = await Self.withTimeout(swapPSTimeout) {
            try await self.activeLoadedModels()
        }
        guard let loaded else { return false }          // ps 超时/失败 → 放弃
        let tag = model.split(separator: ":").first.map(String.init) ?? model
        let inMemory = loaded.contains { x in
            x == model || x.split(separator: ":").first.map(String.init) == tag
        }
        guard inMemory else { return false }            // 不在内存 → 不触发「为卸载而加载」
        let ok = await Self.withTimeout(swapTimeout) {
            try await self.activeUnload(model)
        }
        return ok ?? false
    }

    // MARK: - 换装编排前置钩子（全部失败静默，绝不阻塞对话主流程）

    /// 方向①（L124-146）：即将 ensure_server 加载数 GB 权重前，先卸活动后端
    /// 驻留模型。degraded（活动侧即 MP）跳过；list 失败/空跳过；逐个 safeUnload。
    public func preSwapToPack() async {
        if degraded() { return }   // 退化模式：驱动自己管换装
        let loaded: [String]
        do {
            loaded = try await activeLoadedModels()
        } catch {
            return
        }
        guard !loaded.isEmpty else { return }
        for name in loaded {
            _ = await safeUnload(name)   // 卸载只是内存优化，失败不阻塞对话
        }
        log("换装编排：路由至模型包前已请求卸载活动后端驻留模型 \(loaded)")
    }

    /// 方向②（L148-162）：路由命中活动后端，llama-server 在跑则先停（还内存）
    /// 再放行；stop 失败记日志但不阻断对话。
    public func preSwapToActive() async {
        guard driver.activePack() != nil else { return }   // 廉价状态查询
        let stopped = await driver.stopServer()
        if stopped {
            log("换装编排：路由至活动后端前已停止 llama-server（释放内存）")
        }
    }
}

// ════════════════════════════════════════════════════════════
// MARK: - 路由连接器（routing.py chat/chat_stream L165-186 逐行为）
// ════════════════════════════════════════════════════════════

/// 按 model 名归边的对话连接器（Python RoutingConnector 的对话面）。loop 每一轮
/// （含工具续轮）都经本连接器重新路由+前置钩子——与 Python「loop 的连接器就是
/// RoutingConnector」同构，不在入口做一次判定后锁死。
public struct NativeRoutingChatConnector: NativeChatConnector {
    public let router: NativeModelPackRouter
    public let mp: any NativeChatConnector
    /// 活动后端连接器（按 config 动态解析后的当轮快照；degraded 下为 MP 自身，
    /// 与 routing.py _active() 退化口径一致——此时永不被调用）。
    public let active: any NativeChatConnector

    public init(router: NativeModelPackRouter, mp: any NativeChatConnector,
                active: any NativeChatConnector) {
        self.router = router
        self.mp = mp
        self.active = active
    }

    public func chatStream(model: String, messages: [[String: JSONValue]],
                           tools: [JSONValue]?, images: [String]?)
        -> AsyncThrowingStream<NativeChatStreamEvent, Error> {
        let toPack = router.routeToPack(model)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    // 前置钩子（gen 首次消费时执行，Python async gen 同款惰性）：
                    // 命中包 → 方向①卸活动后端驻留；命中活动后端 → 方向②停 llama-server
                    if toPack {
                        await router.preSwapToPack()
                        for try await ev in mp.chatStream(model: model, messages: messages,
                                                          tools: tools, images: images) {
                            continuation.yield(ev)
                        }
                    } else {
                        await router.preSwapToActive()
                        for try await ev in active.chatStream(model: model, messages: messages,
                                                              tools: tools, images: images) {
                            continuation.yield(ev)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    public func chat(model: String, messages: [[String: JSONValue]]) async throws -> String {
        if router.routeToPack(model) {
            await router.preSwapToPack()
            return try await mp.chat(model: model, messages: messages)
        }
        await router.preSwapToActive()
        return try await active.chat(model: model, messages: messages)
    }
}
