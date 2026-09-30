//
//  NativeMPMLXDriver.swift
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

//  背景：0.7.5 W10 交付「魔塔链接安装」（NativeModelScopeInstaller），GGUF 链
//  经 llama.cpp 闭环，MLX 仓（config.json + safetensors + tokenizer 平铺目录）
//  下载登记后缺推理出口。本文件把该缺口接到既有 mlx-swift-lm 装载链
//  （NativeVModelMLXEngine，0.7.3 起正式化；loadModelContainer 本地目录口径，
//  零网络）：
//    · NativeMPMLXDriver——模型包 MLX 引擎单槽常驻管理（与 NativeVModelChatRouter
//      H1 同款纪律：同一时刻只持有一份引擎，换装先卸旧，宁可中途回空槽也不让
//      两份大模型瞬时共存撑爆统一内存）。装载前置校验链：
//        ① 注册表门禁（未安装/已禁用，llama 驱动 enabledEntry 同款文案口径）；
//        ② config.json 在盘、可解析为 JSON 对象、含非空 model_type；
//        ③ model_type 在 mlx-swift-lm LLMTypeRegistry 支持表内——不支持则
//          「该模型暂不支持」诚实报错（业主红线：绝不静默换模型）；
//      上下文档解析链 = 显式档位（lazy tiers）> manifest context_length > 4096
//      （NativeVModelInstaller standard 档默认同款）；
//    · NativeMPMLXChatConnector——NativeChatConnector 面：流式事件经
//      NativeVModelStreamMap 映射（content delta / 流末真值 done / toolCall，
//      与 .vmodel 路同口径，REQ-INFER-011 不估算填充）；取消静默收尾（ollama/
//      vmodel 同款）；驱动错误映 NativeChatConnectorError.openAI 400（llama 支路
//      NativeLlamaServerError 映射同款惯例，SSE error 事件直展中文提示）。
//  内存编排（换装对称，均在 NativeMPChatConnector 分派层 best-effort 执行，
//  失败不阻断对话）：MLX 支路起手先停 llama-server；GGUF 支路起手先卸 MLX
//  驻留引擎。禁用/移除经 NativeModelPackEndpoints.releasePackRuntime 回收。
//

import Foundation
import MLXLLM
import MLXLMCommon
import VetarModelSDK

// ════════════════════════════════════════════════════════════
// MARK: - 错误（文案自持；连接器层映 NativeChatConnectorError.openAI 400）
// ════════════════════════════════════════════════════════════

/// MLX 模型包推理错误（中文提示逐字自持，端对端直展用户；诚信红线口径——
/// 失败如实上报，绝不静默换模型）。
public enum NativeMPMLXError: Error, Equatable {
    /// 注册表无条目
    case notInstalled(String)
    /// 已禁用
    case disabled(String)
    /// 仓不完整（缺 config.json / 权重未落位等；完整文案自持）
    case incomplete(String)
    /// mlx-swift-lm 不支持（架构不在支持表 / config.json 无法识别；完整文案自持）
    case unsupported(String)
    /// 引擎装载/生成底层失败（完整文案自持）
    case loadFailed(String)

    public var message: String {
        switch self {
        case .notInstalled(let pid):
            return "模型包 \(PySem.reprString(pid)) 未安装。请到「模型包」面板安装后再对话。"
        case .disabled(let pid):
            return "模型包 \(PySem.reprString(pid)) 已禁用。请到「模型包」面板启用后再对话。"
        case .incomplete(let m), .unsupported(let m), .loadFailed(let m):
            return m
        }
    }
}

// ════════════════════════════════════════════════════════════
// MARK: - 驱动（引擎单槽常驻 + 装载前置校验链）
// ════════════════════════════════════════════════════════════

public actor NativeMPMLXDriver {

    public let store: NativeModelPackStore

    /// 引擎装载缝（生产 = 真 mlx-swift-lm 本地目录装载；测试注入假引擎——
    /// 绝不触模型文件，NativeVModelChatRouter.engineLoader 同款先例）。
    public var engineLoader: @Sendable (String, URL, Int) async throws -> NativeVModelMLXEngine
    /// 架构支持表查询缝（生产 = LLMTypeRegistry.shared.contains——即
    /// mlx-swift-lm 本版可实例化的 model_type 全集；测试注入固定表，
    /// 钉桩不随依赖升降漂移）。
    public var supportsModelType: @Sendable (String) async -> Bool

    /// 引擎槽：key = 包目录路径（同包换装判定锚点，与 vmodel 路由同款）。
    private var active: (key: String, packId: String, engine: NativeVModelMLXEngine)?

    public init(store: NativeModelPackStore) {
        self.store = store
        self.engineLoader = { packId, dir, ctx in
            let engine = NativeVModelMLXEngine()
            try await engine.load(modelID: packId, contextLength: ctx, baseDir: dir)
            return engine
        }
        self.supportsModelType = { await LLMTypeRegistry.shared.contains($0) }
    }

    /// 当前驻留包（只读查询，无清理副作用；llama activePack() 同款口径）。
    public var activePackId: String? { active?.packId }

    /// 选中装载：门禁 → 仓结构 → 架构支持 → 单槽换装 → 返回常驻引擎。
    /// - contextLength：档位表当前档（调用方解析）；nil 落 manifest/默认链。
    /// 任何一环失败抛 NativeMPMLXError（中文提示自持）——绝不静默换模型。
    @discardableResult
    public func ensureLoaded(packId: String, contextLength: Int? = nil)
        async throws -> NativeVModelMLXEngine {
        // ① 注册表门禁（llama 驱动 enabledEntry 同款文案口径）
        guard let entry = store.getEntry(packId) else {
            throw NativeMPMLXError.notInstalled(packId)
        }
        guard entry["status"]?.string == "installed" else {
            throw NativeMPMLXError.disabled(packId)
        }
        let dir = try store.packDir(packId)
        // ② 仓结构：config.json 在盘、可解析、含非空 model_type
        //   （权重文件在盘由注册表 missing_files 探测 + 安装期
        //   ModelScopeMLXValidator 双重把关；此处纵深防御只查装载要件）
        let cfgURL = dir.appendingPathComponent("config.json")
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: cfgURL.path, isDirectory: &isDir), !isDir.boolValue else {
            throw NativeMPMLXError.incomplete(
                "MLX 模型包不完整（缺 config.json——安装不完整或文件被手动删除），"
                + "请到「模型包」面板重新安装。")
        }
        guard let data = try? Data(contentsOf: cfgURL),
              case .object(let cfg)? = NativeJSONWriter.loads(data) else {
            throw NativeMPMLXError.incomplete(
                "MLX 模型包不完整（config.json 不是合法 JSON），请到「模型包」面板重新安装。")
        }
        guard let modelType = cfg["model_type"]?.string, !modelType.isEmpty else {
            throw NativeMPMLXError.unsupported(
                "该模型暂不支持：config.json 未声明 model_type，本机 MLX 推理无法识别"
                + "其架构（模型文件已保留，未做任何替换）。")
        }
        // ③ 架构支持表（业主红线：不支持诚实报错，不静默换模型）
        guard await supportsModelType(modelType) else {
            throw NativeMPMLXError.unsupported(
                "该模型暂不支持：架构「\(modelType)」暂不在本机 MLX 推理支持列表内"
                + "（模型文件已保留，未做任何替换）。")
        }
        let ctx = Self.resolveContextLength(explicit: contextLength,
                                            store: store, packId: packId)
        if active?.key != dir.path {
            // H1 同款换装：先卸旧再载新（宁可中途回空槽；新载失败抛错，
            // 绝不静默换回旧模型）
            if let old = active {
                await old.engine.unload()
                active = nil
            }
            do {
                let engine = try await engineLoader(packId, dir, ctx)
                active = (dir.path, packId, engine)
            } catch let e as NativeMPMLXError {
                throw e
            } catch {
                throw NativeMPMLXError.loadFailed(
                    "MLX 模型装载失败：\(String(describing: error).prefix(200))")
            }
        } else if let engine = active?.engine {
            // 同包异档免重载：maxKVSize 每轮 generate 消费（见引擎
            // setContextLength 注释），换挡只更新消费值
            await engine.setContextLength(ctx)
        }
        guard let engine = active?.engine else {
            throw NativeMPMLXError.loadFailed("MLX 引擎装配失败（内部状态异常）")
        }
        return engine
    }

    /// 卸载：packId 给定时只卸匹配项（llama stopServer(packId) 同款名字匹配防护，
    /// 不误卸在跑的对话）；nil 卸当前驻留。返回是否真卸了。
    @discardableResult
    public func unload(_ packId: String? = nil) async -> Bool {
        guard let a = active else { return false }
        if let packId, a.packId != packId { return false }
        await a.engine.unload()
        active = nil
        return true
    }

    /// ctx 解析链：显式档位（正整数）> manifest context_length（正整数才采纳）>
    /// 4096（NativeVModelInstaller standard 档默认同款）。
    static func resolveContextLength(explicit: Int?, store: NativeModelPackStore,
                                     packId: String) -> Int {
        if let explicit, explicit > 0 { return explicit }
        if case .int(let n)? = store.readManifest(packId)["context_length"], n > 0 {
            return Int(n)
        }
        return NativeVModelInstaller.contextLength(for: .standard)
    }

    // MARK: - 测试缝（@testable 专用；生产零调用——vmodel 路由同款先例）

    internal var activePackDirForTest: String? { active?.key }

    /// 跨 actor 设置装载缝（actor 隔离属性外部不可直写；
    /// NativeVModelChatRouter.setEngineLoader 同款先例）
    public func setEngineLoader(
        _ l: @escaping @Sendable (String, URL, Int) async throws -> NativeVModelMLXEngine
    ) { engineLoader = l }
    /// 跨 actor 设置架构支持表缝（钉桩固定表，不随依赖升降漂移）
    public func setSupportsModelType(_ s: @escaping @Sendable (String) async -> Bool) {
        supportsModelType = s
    }
}

// ════════════════════════════════════════════════════════════
// MARK: - 连接器（NativeChatConnector 面；流式/聚合双出口）
// ════════════════════════════════════════════════════════════

/// MLX 模型包聊天连接器。与 NativeMPChatConnector 平级同协议——分派在
/// NativeMPChatConnector 内按注册表 driver 键归边（driver=mlxswift → 本支路）。
public final class NativeMPMLXChatConnector: NativeChatConnector, @unchecked Sendable {

    public let driver: NativeMPMLXDriver
    public let tiers: NativeLazyCtxTiers
    /// 流式缝（生产 = 驱动装载 + 引擎真流经 NativeVModelStreamMap 映射；
    /// 测试注入脚本化事件流，绝不触模型文件——NativeVModelRoutingConnector
    /// .vmodelStream 同款先例）。
    var streamImpl: @Sendable (String, [[String: JSONValue]], [JSONValue]?)
        -> AsyncThrowingStream<NativeChatStreamEvent, Error>
    /// 聚合缝（报错分析等极简面；测试注入脚本化文本）。
    var chatImpl: @Sendable (String, [[String: JSONValue]]) async throws -> String

    /// 生产装配：驱动 + 内核共享档位表（loop 升档与引擎换挡同一份状态，
    /// 与 llama 支路 tiers 语义同款）。
    public init(driver: NativeMPMLXDriver, tiers: NativeLazyCtxTiers) {
        self.driver = driver
        self.tiers = tiers
        self.streamImpl = { model, messages, tools in
            Self.productionStream(driver: driver, tiers: tiers,
                                  model: model, messages: messages, tools: tools)
        }
        self.chatImpl = { model, messages in
            try await Self.productionChat(driver: driver, tiers: tiers,
                                          model: model, messages: messages)
        }
    }

    /// 测试注入缝：脚本化事件流/聚合文本。
    public init(driver: NativeMPMLXDriver, tiers: NativeLazyCtxTiers,
                streamImpl: @escaping @Sendable (String, [[String: JSONValue]], [JSONValue]?)
                    -> AsyncThrowingStream<NativeChatStreamEvent, Error>,
                chatImpl: @escaping @Sendable (String, [[String: JSONValue]])
                    async throws -> String) {
        self.driver = driver
        self.tiers = tiers
        self.streamImpl = streamImpl
        self.chatImpl = chatImpl
    }

    public func chatStream(model: String, messages: [[String: JSONValue]],
                           tools: [JSONValue]?, images: [String]?)
        -> AsyncThrowingStream<NativeChatStreamEvent, Error> {
        // images 不接（MLX 仓契约当前纯文本；与 .vmodel 路由连接器同口径，
        // 多模态诉求登记遗留）
        streamImpl(model, messages, tools)
    }

    public func chat(model: String, messages: [[String: JSONValue]]) async throws -> String {
        try await chatImpl(model, messages)
    }

    /// GGUF 支路换装对称②的执行体：llama 路起手前卸本支路驻留引擎
    /// （best-effort，无驻留零副作用）。
    public func unloadActive() async { _ = await driver.unload() }

    /// unload_model 面（名字匹配防护在驱动层）。
    public func unload(_ packId: String) async -> Bool { await driver.unload(packId) }

    /// 驱动错误 → NativeChatConnectorError.openAI 400（llama 支路
    /// NativeLlamaServerError 映射同款惯例；SSE error 事件直展中文提示）。
    /// 其余底层异常 → 「MLX 模型推理失败：…」诚实文案；取消原样上透
    /// （取消不是推理失败，调用方按取消语义收尾）。
    static func mapError(_ error: Error) -> Error {
        if let e = error as? NativeMPMLXError {
            return NativeChatConnectorError.openAI(status: 400, message: e.message, detail: "")
        }
        return NativeChatConnectorError.openAI(
            status: 400,
            message: "MLX 模型推理失败：\(String(describing: error).prefix(200))",
            detail: "")
    }

    /// 生产流式：档位解析 → 驱动装载 → 引擎真流映射。取消静默收尾
    /// （引擎流随释放走 onTermination，不回写脏 prefixCache——与 .vmodel
    /// 路由 W5 纪律同款）。
    static func productionStream(driver: NativeMPMLXDriver, tiers: NativeLazyCtxTiers,
                                 model: String, messages: [[String: JSONValue]],
                                 tools: [JSONValue]?)
        -> AsyncThrowingStream<NativeChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let tier = tiers.currentCtxFor(model, backend: "model_package")
                    let engine = try await driver.ensureLoaded(packId: model,
                                                               contextLength: tier)
                    // 主会话长答口径 4096（与 .vmodel 路由连接器 maxTokens 同款）
                    let stream = try await engine.chatStream(messages: messages,
                                                             maxTokens: 4096, tools: tools)
                    for await gen in stream {
                        try Task.checkCancellation()
                        if let ev = NativeVModelStreamMap.event(for: gen) {
                            continuation.yield(ev)
                        }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: mapError(error))
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    /// 生产聚合（报错分析等极简面；maxTokens 1024 与工作室聚合路同口径）。
    /// 取消原样上透（取消不是推理失败），其余异常经 mapError 映中文提示。
    static func productionChat(driver: NativeMPMLXDriver, tiers: NativeLazyCtxTiers,
                               model: String, messages: [[String: JSONValue]])
        async throws -> String {
        do {
            let tier = tiers.currentCtxFor(model, backend: "model_package")
            let engine = try await driver.ensureLoaded(packId: model, contextLength: tier)
            let stream = try await engine.chatStream(messages: messages, maxTokens: 1024)
            var content = ""
            for await gen in stream {
                try Task.checkCancellation()
                if case .chunk(let s) = gen { content += s }
            }
            guard !content.isEmpty else {
                throw NativeMPMLXError.loadFailed("MLX 模型推理失败：生成内容为空")
            }
            return content
        } catch let e as CancellationError {
            throw e
        } catch {
            throw mapError(error)
        }
    }
}
