//
//  NativeInferenceEndpoints.swift
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

//  逐行为移植（⛔ 只读行为规格源：subagent/sidecar/app.py + sidecar/ollama/*）：
//    · GET /api/inference/status      app.py L446-472（8s 探活 + 能力表 + base_url 三分支）
//    · GET /api/inference/models      app.py L474-498（统一列表行映射 + 502 文案）
//    · POST /api/ollama/pull          app.py L428-435（能力表门控 400 逐字 + NDJSON 行透传）
//    · DELETE /api/ollama/models/{n}  app.py L437-444（能力表门控 400 逐字 + deleted:false 不抛错）
//    · GET /api/context/limit         app.py L500-592（四级回退 config→ps→show→262144
//                                     + unsupported/error 分支 + 懒加载当前档 ceiling/lazy）
//    · 能力表唯一事实源               connector.py L105-108（ollama 全真）/
//                                     openai_compat.py L127-132（tools 读配置，pull/delete 假）/
//                                     mp_connector.py L107-116（tools 真，余皆假）
//    · 路由连接器口径                 routing.py L189-205（list_models 并集 + source 标注；
//                                     L81-89 _active 解析：openai_compatible→openai，
//                                     model_package→MP，其余含未知值→ollama）
//
//  MP（model_package）分支纪律（P3-W3 前 MP 运行时未原生）：
//    ① backend=model_package 时 status/models/context-limit **整端点**由调用方
//       （NativeSidecarClient+Panels）HTTP 转发——status 的 base_url 是驱动活动服务动态端口、
//       models 并集退化为全 MP、context-limit 走包 manifest 分支，均依赖侧车 MP 运行时；
//       先例 = chatStream 按 inference_backend 分流（NativeSidecarClient.chatStream）。
//    ② ollama/openai 后端下 models 并集的**模型包部分**经 mpUnion 参数 HTTP 回源
//       （/api/model-packs → 启用中 chat 包映射，mp_connector.list_models L93-105 同口径）；
//       侧车缺席时调用方降级空并集，活动后端名单不受影响。
//    ③ pull/delete 无 MP 面：能力表先行 400 拦截（Python 同口径），永不触达 MP。
//
//  事件口径（A13 核查）：Python 推理写端点（pull/delete）**不**发 resource_changed——
//    RESOURCE_INFERENCE 唯一发布点是 PUT /api/config（app.py L272，updateConfig 原生路径
//    已接 NativeEndpointNotify）。故本装配零 notify，逐字复刻。
//
//  偏差（汇报清单同步）：
//    ① status 探活的 detail：超时分支文案逐字（连接超时（8s）…）；其余异常取
//       Swift 错误描述前 200 字——Python str(e) 与其不同源（httpx vs URLError），
//       诊断文本不逐字，语义等价（仅展示用途）。
//    ② 探活名单只查活动后端（Python 查并集 = 活动 + MP 注册表）。MP 注册表读取
//       不产生可失败项，online 判定语义不变（routing.py L36 注释同款口径）。
//    ③ /api/show 的 model_info 多键命中时取任一键（Python 取 JSON 文档序首键；
//       实测 model_info 只有一个 <架构>.context_length 键，多键形态不存在）。
//    ④ 懒加载档位表注入内核级共享实例（NativeKernel.lazyCtxTiers）；
//       NativeChatEndpoints.gen() 每流自建实例的 W4a 偏差②不动——本端点报起始档
//       与原生 chat 下一次实际注入值同口径（两侧都是各自实例首访问起始档）。
//    ⑤ modelsMP（退化面）0.7.5 工程遗留③ / W3 起并 .vmodel 启用集（Python 退化
//       只回 MP 列表，routing.py L196-197）：REQ-FUT-020「任何功能均可使用
//       VetarModel 所制作的模型」的退化面补齐；主后端（ollama/openai）清单不并——
//       退化判定下其模型不可路由，列入即虚标。
//

import Foundation

// ════════════════════════════════════════════════════════════
// MARK: - 错误（探活超时判型 + openai 地址缺失逐字文案）
// ════════════════════════════════════════════════════════════

public enum NativeInferenceError: Error, CustomStringConvertible {
    /// asyncio.wait_for 8s 超时等价（app.py L457-459 分支判据）。
    case probeTimeout
    /// openai_compat._base() L77-78：地址未配置（detail 逐字）。
    case backendURLMissing
    /// 活动后端地址非法（无法构造 URL）。
    case badBase(String)
    /// 非 2xx（raise_for_status 等价；附状态码与响应摘要）。
    case httpStatus(Int, String)
    /// 传输层失败包装（连接拒绝/DNS/TLS 等）。
    case transport(String)

    public var description: String {
        switch self {
        case .probeTimeout: return "probe timeout"
        case .backendURLMissing: return "推理后端地址未配置（设置面板：推理后端 → 地址）"
        case .badBase(let b): return "后端地址非法: \(b)"
        case .httpStatus(let s, let body): return "HTTP \(s): \(body.prefix(200))"
        case .transport(let m): return m
        }
    }
}

// ════════════════════════════════════════════════════════════
// MARK: - 推理端点装配体
// ════════════════════════════════════════════════════════════

/// 推理面板端点面原生装配（五端点 + 能力表 + 路由并集）。
///
/// 所有出站 HTTP 都经同名 `var` 缝——生产 = 本文件 `live*` 实时 fetcher（直连
/// ollama / openai 兼容后端，不经侧车），测试注入 stub 不触网
/// （ollamaTagsFetcher 先例，commit 5a83700）。class 形态以便测试就地改缝
/// （与 kernel lazy 属性兼容）。
public final class NativeInferenceEndpointAssembly: @unchecked Sendable {

    public let config: NativeConfigStore
    /// 懒加载档位表（infer_options.current_ctx_for/configured_num_ctx 等价）；
    /// 生产注入内核级共享实例（NativeKernel.lazyCtxTiers）。
    public let tiers: NativeLazyCtxTiers
    /// 探活超时秒（app.py L454 asyncio.wait_for(timeout=8.0)）；测试可压小。
    public var probeTimeout: Double

    // MARK: 出站缝（生产 = live*；签名：ollama 系吃 base URL，openai 系吃 base+apiKey）

    /// GET {base}/api/tags → models 原始字典数组（list_models 等价；非 2xx/传输失败抛错）。
    public var ollamaTags: (String) async throws -> [[String: JSONValue]]
    /// GET {base}/models（Authorization: Bearer key）→ id 名单；地址空 → backendURLMissing。
    public var openAIModelIDs: (String, String) async throws -> [String]
    /// GET {base}/api/ps → models 原始字典数组（5s；非 2xx/传输失败抛错）。
    public var ollamaPS: (String) async throws -> [[String: JSONValue]]
    /// POST {base}/api/show {name} → model_info 任意 .context_length（5s；失败/无键 → nil，不抛）。
    public var ollamaShowContextLength: (String, String) async -> Int?
    /// POST {base}/api/pull {name} → NDJSON 非空行原样收集（60s；非 2xx/传输失败抛错）。
    public var ollamaPullLines: (String, String) async throws -> [String]
    /// DELETE {base}/api/delete {name} → status==200（传输失败抛错，非 200 → false）。
    public var ollamaDeleteModel: (String, String) async throws -> Bool

    public init(config: NativeConfigStore, tiers: NativeLazyCtxTiers, probeTimeout: Double = 8.0) {
        self.config = config
        self.tiers = tiers
        self.probeTimeout = probeTimeout
        self.ollamaTags = Self.liveOllamaTags
        self.openAIModelIDs = Self.liveOpenAIModelIDs
        self.ollamaPS = Self.liveOllamaPS
        self.ollamaShowContextLength = Self.liveOllamaShowContextLength
        self.ollamaPullLines = Self.liveOllamaPullLines
        self.ollamaDeleteModel = Self.liveOllamaDeleteModel
    }

    // MARK: - 配置读取（get_config() 每次调用动态读同款；失败回落默认合并表）

    func cfg() -> [String: JSONValue] {
        (try? config.getConfig()) ?? NativeConfigStore.defaultConfig
    }

    /// routing.py _backend()（L72-75）：config 原值 strip。
    static func backendStripped(_ cfg: [String: JSONValue]) -> String {
        (cfg["inference_backend"]?.string ?? "ollama").trimmingCharacters(in: .whitespaces)
    }

    /// OllamaConnector.__init__（connector.py L76-79）：config 键 + rstrip "/"
    /// （键缺省回落 localhost，与 fetchOllamaModelNames 同款）。
    static func ollamaBase(_ cfg: [String: JSONValue]) -> String {
        (cfg["ollama_base_url"]?.string ?? "http://localhost:11434")
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
    }

    // MARK: - 能力表（端点守卫与前端渲染的唯一事实源）

    /// connector.capabilities() 逐字（routing.py L208-209 活动后端原样透传）：
    /// ollama 全真（connector.py L105-108）；openai_compatible tools 读
    /// openai_compat_supports_tools（缺省 true）、vision 真、pull/delete 假
    /// （openai_compat.py L127-132）；model_package tools 真、余皆假（mp_connector.py L107-116）。
    /// 未知后端值落 ollama 行（routing.py _active() else 分支同款）。
    public static func capabilities(backend: String, cfg: [String: JSONValue]) -> InferenceCapabilities {
        switch backend {
        case "openai_compatible":
            return InferenceCapabilities(
                tools: cfg["openai_compat_supports_tools"]?.bool ?? true,
                vision: true, pull: false, delete: false)
        case "model_package":
            return InferenceCapabilities(tools: true, vision: false, pull: false, delete: false)
        default:
            return InferenceCapabilities(tools: true, vision: true, pull: true, delete: true)
        }
    }

    // MARK: - GET /api/inference/status（app.py L446-472）

    /// ⚠️ 前置：backend=model_package 由调用方整端点 HTTP 转发（MP base_url 是驱动
    /// 动态端口，P3-W3 前不可得）；本方法只覆盖 ollama/openai_compatible 面。
    public func status() async -> InferenceStatusInfo {
        let cfg = cfg()
        let backend = Self.backendStripped(cfg)
        let caps = Self.capabilities(backend: backend, cfg: cfg)
        // base_url 三分支（L463-470；model_package 分支在调用方 HTTP 面，不到这里）
        let baseURL = backend == "ollama"
            ? (cfg["ollama_base_url"]?.string ?? "")
            : (cfg["inference_base_url"]?.string ?? "")
        var online = true
        var detail = ""
        do {
            try await withProbeTimeout { try await self.probeActiveModels(backend: backend, cfg: cfg) }
        } catch NativeInferenceError.probeTimeout {
            online = false
            detail = "连接超时（8s），请检查地址是否正确、服务是否启动"   // L459 逐字
        } catch {
            online = false
            detail = String(String(describing: error).prefix(200))        // L462 str(e)[:200]
        }
        return InferenceStatusInfo(backend: backend, base_url: baseURL,
                                   online: online, detail: detail, capabilities: caps)
    }

    /// 探活名单（偏差②：只查活动后端；MP 注册表无失败项，online 语义不变）。
    private func probeActiveModels(backend: String, cfg: [String: JSONValue]) async throws {
        if backend == "openai_compatible" {
            _ = try await openAIModelIDs(Self.openAIBase(cfg), Self.openAIKey(cfg))
        } else {
            _ = try await ollamaTags(Self.ollamaBase(cfg))
        }
    }

    /// asyncio.wait_for 竞速（先到者赢；输者随 group.cancelAll 取消）。
    private func withProbeTimeout(_ work: @escaping @Sendable () async throws -> Void) async throws {
        let seconds = probeTimeout
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw NativeInferenceError.probeTimeout
            }
            _ = try await group.next()
            group.cancelAll()
        }
    }

    static func openAIBase(_ cfg: [String: JSONValue]) -> String {
        (cfg["inference_base_url"]?.string ?? "")
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
    }

    static func openAIKey(_ cfg: [String: JSONValue]) -> String {
        (cfg["inference_api_key"]?.string ?? "").trimmingCharacters(in: .whitespaces)
    }

    // MARK: - GET /api/inference/models（app.py L474-498）

    /// 统一模型列表：活动后端（标 source=后端名，routing.py L198-204）+ mpUnion()
    /// 回源的模型包并集（MP 部分，P3-W3 前 HTTP）+ vmodelUnion() 回源的 .vmodel
    /// 并集（REQ-FUT-020 0.7.5 W1：source="vmodel" 同款来源标注；缺省空集不动原口径）。
    /// ⚠️ 前置：backend=model_package（退化模式）由调用方整端点 HTTP 转发。
    /// 活动后端失败 → httpError(502, "推理后端不可达：…")（L479-481 逐字前缀）。
    public func models(mpUnion: () async -> [InferenceModelEntry],
                       vmodelUnion: () async -> [InferenceModelEntry] = { [] }) async throws
        -> [InferenceModelEntry] {
        let cfg = cfg()
        let backend = Self.backendStripped(cfg)
        let active: [[String: JSONValue]]
        do {
            if backend == "openai_compatible" {
                // openai_compat.list_models（L402-407）：[{name: id}]
                active = try await openAIModelIDs(Self.openAIBase(cfg), Self.openAIKey(cfg))
                    .map { ["name": .string($0)] }
            } else {
                active = try await ollamaTags(Self.ollamaBase(cfg))
            }
        } catch {
            throw SidecarError.httpError(status: 502,
                                         detail: "推理后端不可达：\(String(describing: error))")
        }
        // routing.py L200-203：活动后端逐项标 source=后端名（已有 source 不覆盖）
        var out = active.compactMap { m -> InferenceModelEntry? in
            var m = m
            if m["source"]?.string == nil { m["source"] = .string(backend) }
            return Self.endpointRow(m)
        }
        out.append(contentsOf: await mpUnion())
        // REQ-FUT-020（0.7.5 W1）：.vmodel 平级入并集（工作流节点/设置默认模型下拉同源）
        out.append(contentsOf: await vmodelUnion())
        return out
    }

    /// 端点行映射（app.py L483-497 逐行为）：name = m.name || m.id || ""（空跳过）；
    /// "size" 键在则带（缺省 0）；ctx = details.context_length 或 context_length（真值才带）；
    /// source 真值才带。
    static func endpointRow(_ m: [String: JSONValue]) -> InferenceModelEntry? {
        let name = m["name"]?.string ?? m["id"]?.string ?? ""
        guard !name.isEmpty else { return nil }
        var size: Int64? = nil
        if m.keys.contains("size") {
            size = m["size"].flatMap(PySem.toFloat).map { Int64($0) } ?? 0
        }
        var ctx = truthyNumber(m["details"]?.object?["context_length"])
        if ctx == nil { ctx = truthyNumber(m["context_length"]) }
        let source = m["source"]?.string
        return InferenceModelEntry(
            name: name, size: size,
            context_length: ctx.map { Int($0) },
            source: (source?.isEmpty == false) ? source : nil)
    }

    /// Python 真值语义：数值非 0 才真（None/0 → 假，走 or 下一棒 / 不携带）。
    static func truthyNumber(_ v: JSONValue?) -> Double? {
        guard let f = v.flatMap(PySem.toFloat), f != 0 else { return nil }
        return f
    }

    // MARK: - POST /api/ollama/pull（app.py L428-435）

    /// 能力表 pull=false → 400 逐字（M6 TS-112：能力表是唯一事实源；MP/openai 因此
    /// 无需 HTTP 转发）。通过 → 直连 ollama /api/pull 收集 NDJSON 行全量返回。
    public func pull(name: String) async throws -> [String] {
        let cfg = cfg()
        guard Self.capabilities(backend: Self.backendStripped(cfg), cfg: cfg).pull else {
            throw SidecarError.httpError(
                status: 400, detail: "当前推理后端不支持模型拉取（仅 Ollama 后端支持）")   // L433 逐字
        }
        return try await ollamaPullLines(Self.ollamaBase(cfg), name)
    }

    // MARK: - DELETE /api/ollama/models/{name}（app.py L437-444）

    /// 能力表 delete=false → 400 逐字。通过 → deleted 布尔如实返回（false 不抛错，
    /// 端点 200 {"deleted": false} 口径）。
    public func delete(name: String) async throws -> Bool {
        let cfg = cfg()
        guard Self.capabilities(backend: Self.backendStripped(cfg), cfg: cfg).delete else {
            throw SidecarError.httpError(
                status: 400, detail: "当前推理后端不支持模型删除（仅 Ollama 后端支持）")   // L442 逐字
        }
        return try await ollamaDeleteModel(Self.ollamaBase(cfg), name)
    }

    // MARK: - GET /api/context/limit（app.py L500-592）

    /// 四级取值（A3）：config（懒加载生效报当前档 + ceiling/lazy）→ ps → show → 262144。
    /// openai_compatible → unsupported；活动后端不可达 → error。
    /// ⚠️ 前置：backend=model_package（包 manifest 分支）由调用方整端点 HTTP 转发——
    /// 注意 app.py L528-529 后端判定**不 strip**，调用方按同口径转发。
    public func contextLimit(model: String) async -> ContextLimitInfo {
        let cfg = cfg()
        // L528：str(cfg.get("inference_backend", "ollama"))——无 strip（与 status 不同，逐字）
        let backend = cfg["inference_backend"]?.string ?? "ollama"
        guard backend == "ollama" else {
            // L544-545（model_package 分支在调用方 HTTP 面，不到这里）
            return ContextLimitInfo(limit: 0, source: "unsupported")
        }

        // 第 1 级：用户显式配置的 num_ctx（L547-558；三级键匹配在 tiers 内）
        if let nc = tiers.configuredNumCtx(model) {
            // 0.4.31（D4）：懒加载生效 → 报当前档并追加 ceiling/lazy
            if let tier = tiers.currentCtxFor(model) {
                return ContextLimitInfo(limit: tier, source: "config", ceiling: nc, lazy: true)
            }
            return ContextLimitInfo(limit: nc, source: "config")
        }

        let base = Self.ollamaBase(cfg)
        // 第 2 级：/api/ps（L565-575；请求失败 → error，不落 show——外层 except 口径）
        let ps: [[String: JSONValue]]
        do { ps = try await ollamaPS(base) } catch {
            return ContextLimitInfo(limit: 0, source: "error")   // L591-592
        }
        for m in ps {
            guard let name = m["name"]?.string else { continue }
            guard name == model || name.hasPrefix(model + ":") || name.hasPrefix(model) else { continue }
            // cl 假值不返回——继续扫下一个匹配模型（L573-575 无 break 口径）
            if let cl = Self.truthyNumber(m["context_length"])
                ?? Self.truthyNumber(m["details"]?.object?["context_length"]) {
                return ContextLimitInfo(limit: Int(cl), source: "ps")
            }
        }
        // 第 3 级：/api/show（L580-588；失败不致命 → 落兜底）
        if let v = await ollamaShowContextLength(base, model) {
            return ContextLimitInfo(limit: v, source: "show")
        }
        // 第 4 级：兜底（L590 协议常量：qwen 系默认上限）
        return ContextLimitInfo(limit: 262144, source: "default")
    }

    // ════════════════════════════════════════════════════════
    // MARK: - P3-W3a model_package 面（MP 分支翻原生）
    // ════════════════════════════════════════════════════════

    /// MP 缝：活动服务 base_url（驱动动态端口；未启动 nil）。生产=kernel.llamaDriver。
    public var mpActiveBaseURL: @Sendable () -> String? = { nil }
    /// MP 缝：注册表聚合列表（mp_connector.list_models L93-105 同口径）。
    /// 生产=kernel.mpChatConnector.listModels()。
    public var mpListModels: @Sendable () -> [[String: JSONValue]] = { [] }
    /// MP 缝：包 manifest 可选键 context_length（正整数才采纳；未声明/非法 nil）。
    /// 生产=kernel.modelPackStore.readManifest。
    public var mpManifestContextLength: @Sendable (String) -> Int? = { _ in nil }
    /// MP 缝：modelsMP 并集的 .vmodel 部分（REQ-FUT-020 0.7.5 工程遗留③ / W3：
    /// modelsMP 退化后端未并集收口——W1 只把 .vmodel 并入 models() 活动后端面，
    /// 退化面被落下）。生产=kernel.vmodelInstaller 注册表直读（enabled 条目，
    /// source="vmodel"）；缺省空集不动原口径（与 mpUnion/vmodelUnion 缝同款先例）。
    public var mpVModelUnion: @Sendable () -> [InferenceModelEntry] = { [] }

    /// GET /api/inference/status 的 model_package 面（app.py L446-472，P3-W3a）：
    /// caps=MP 能力表（routing 退化透传 MP 表，routing.py L208-209+L52-53）；
    /// probe=routing 退化 list_models=MP 注册表读——无失败项，wait_for 永不超时，
    /// online 恒 true；base_url=驱动活动动态端口（未启动空串，不影响 online 判定，
    /// L466-468 注释同款）。
    public func statusMP() -> InferenceStatusInfo {
        let cfg = cfg()
        return InferenceStatusInfo(
            backend: "model_package",
            base_url: mpActiveBaseURL() ?? "",
            online: true, detail: "",
            capabilities: Self.capabilities(backend: "model_package", cfg: cfg))
    }

    /// GET /api/inference/models 的 model_package 面（app.py L474-498 +
    /// routing.py L196-197 退化只回 MP 列表；注册表读无 502 分支）。
    /// REQ-FUT-020 0.7.5 工程遗留③ / W3：追加 .vmodel 并集（mpVModelUnion 缝，
    /// 与 models() 的 vmodelUnion 同真源）——W1「任何功能均可使用 VetarModel
    /// 所制作的模型」在退化面补齐；MP 主清单 ∪ .vmodel 启用集按 name 去重
    /// （先见者赢，同模型不重复出现；source 标注原样保留不改写）。
    /// ⚠️ 规格偏差登记：Python 退化面不并 .vmodel（W1 前无此物）；ollama/openai
    /// 主后端清单**不**并入——退化判定下 routeToPack 全走 MP，主后端模型不可用，
    /// 列入即虚标（routing.py L196-197 同口径）。
    public func modelsMP() -> [InferenceModelEntry] {
        Self.unionDeduped(mpListModels().compactMap(Self.endpointRow), mpVModelUnion())
    }

    /// GET /api/context/limit 的 model_package 面（app.py L529-542，P3-W3a）：
    /// 该包配了 num_ctx 且懒加载开启 → 当前档 + ceiling/lazy（source="config"，D4/D5
    /// 与 Ollama 分支同口径）；否则 manifest 可选键 context_length（与驱动 -c 启动
    /// 参数同源，source="manifest"）；未声明 → unsupported（前端隐藏指示器，不瞎兜底）。
    public func contextLimitMP(model: String) -> ContextLimitInfo {
        if let tier = tiers.currentCtxFor(model, backend: "model_package") {
            return ContextLimitInfo(limit: tier, source: "config",
                                    ceiling: tiers.configuredNumCtx(model) ?? 0, lazy: true)
        }
        if let cl = mpManifestContextLength(model), cl > 0 {
            return ContextLimitInfo(limit: cl, source: "manifest")
        }
        return ContextLimitInfo(limit: 0, source: "unsupported")
    }

    // ════════════════════════════════════════════════════════
    // MARK: - 纯函数片段（live fetcher 复用；测试直锚）
    // ════════════════════════════════════════════════════════

    /// 并集去重纯函数（REQ-FUT-020 0.7.5 工程遗留③ / W3，modelsMP 退化后端并集）：
    /// 主清单原样保留（顺序/字段不动），追加部分按 name 去重——空名跳过、
    /// 同名先见者赢（同模型不重复出现）；source 等标注字段逐字保留，不改写
    /// 不隐藏（可用性由各来源行自身标注承担：model_pack/vmodel 均为注册表
    /// enabled 过滤后的诚实行）。
    public static func unionDeduped(_ base: [InferenceModelEntry],
                                    _ extra: [InferenceModelEntry]) -> [InferenceModelEntry] {
        guard !extra.isEmpty else { return base }
        var seen = Set(base.map(\.name))
        var out = base
        for e in extra where !e.name.isEmpty && !seen.contains(e.name) {
            seen.insert(e.name)
            out.append(e)
        }
        return out
    }

    /// NDJSON 行收集（connector.pull_model L400-403 逐行为）：按行 split，
    /// 空白行（strip 后空）跳过，其余**原样**保留（不去空白）。
    public static func ndjsonLines(_ data: Data) -> [String] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        return text.components(separatedBy: .newlines).filter {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    /// /api/show model_info 扫描（app.py L583-586）：任意以 .context_length 结尾的键，
    /// 整数值 >0 则命中（偏差③：多键取任一；实测单键）。
    public static func showContextLength(from modelInfo: [String: JSONValue]) -> Int? {
        for (k, v) in modelInfo where k.hasSuffix(".context_length") {
            guard let f = PySem.toFloat(v), f > 0 else { continue }
            return Int(f)
        }
        return nil
    }

    // ════════════════════════════════════════════════════════
    // MARK: - 生产实时 fetcher（直连后端；网络仅生产触达）
    // ════════════════════════════════════════════════════════

    /// 2xx 校验（raise_for_status 等价）。
    private static func ensure2xx(_ resp: URLResponse, data: Data) throws {
        guard let http = resp as? HTTPURLResponse else {
            throw NativeInferenceError.transport("非 HTTP 响应")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw NativeInferenceError.httpStatus(
                http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
    }

    /// GET {base}/api/tags → models 原始数组（list_models L160-164 等价；
    /// 30s 余量——探活 8s 上限由 status() 竞速施加，fetcher 自身不抢跑）。
    public static func liveOllamaTags(_ base: String) async throws -> [[String: JSONValue]] {
        guard let url = URL(string: "\(base)/api/tags") else {
            throw NativeInferenceError.badBase(base)
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 30
        let (data, resp) = try await URLSession.shared.data(for: req)
        try ensure2xx(resp, data: data)
        guard let v = NativeJSONWriter.loads(data), case .object(let o) = v,
              case .array(let models)? = o["models"] else { return [] }
        return models.compactMap { $0.object }
    }

    /// GET {base}/models（openai_compat.list_models L402-407 等价）：
    /// 地址空 → backendURLMissing（_base() L77-78 逐字）；带 Bearer 头（L114-116）。
    public static func liveOpenAIModelIDs(_ base: String, _ apiKey: String) async throws -> [String] {
        guard !base.isEmpty else { throw NativeInferenceError.backendURLMissing }
        guard let url = URL(string: "\(base)/models") else {
            throw NativeInferenceError.badBase(base)
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 30
        if !apiKey.isEmpty { req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        let (data, resp) = try await URLSession.shared.data(for: req)
        try ensure2xx(resp, data: data)
        guard let v = NativeJSONWriter.loads(data), case .object(let o) = v,
              case .array(let rows)? = o["data"] else { return [] }
        return rows.compactMap { $0.object?["id"]?.string }.filter { !$0.isEmpty }
    }

    /// GET {base}/api/ps（app.py L566，5s）。
    public static func liveOllamaPS(_ base: String) async throws -> [[String: JSONValue]] {
        guard let url = URL(string: "\(base)/api/ps") else {
            throw NativeInferenceError.badBase(base)
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 5.0
        let (data, resp) = try await URLSession.shared.data(for: req)
        try ensure2xx(resp, data: data)
        guard let v = NativeJSONWriter.loads(data), case .object(let o) = v,
              case .array(let models)? = o["models"] else { return [] }
        return models.compactMap { $0.object }
    }

    /// POST {base}/api/show {name}（app.py L581，5s）：非 200/异常/无键 → nil
    /// （show 失败不致命，落第 4 级兜底）。
    public static func liveOllamaShowContextLength(_ base: String, _ model: String) async -> Int? {
        guard let url = URL(string: "\(base)/api/show") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 5.0
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = NativeDatabase.dumpsUTF8(.object(["name": .string(model)]))
            .data(using: .utf8)
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let v = NativeJSONWriter.loads(data), case .object(let o) = v,
              case .object(let mi)? = o["model_info"] else { return nil }
        return showContextLength(from: mi)
    }

    /// POST {base}/api/show {name} 探测视觉能力（0.7.4 W11 委派 visionProbe 接管）：
    /// 200 且 capabilities 数组存在 → 是否含 "vision"；capabilities 键缺失 / 非 200 /
    /// 异常 → true（「nil/失败 → true 不阻塞」降级口径，对齐 modelSupportsVision 语义）。
    /// ⚠️ 走 URLSession.shared 不可注入——网络路径不测（与 liveOllamaShowContextLength
    /// 同待遇），名称层命中/降级口径由 NativeDelegationEngineTests 覆盖。
    public static func liveOllamaShowSupportsVision(_ base: String, _ model: String) async -> Bool {
        guard let url = URL(string: "\(base)/api/show") else { return true }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 5.0
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = NativeDatabase.dumpsUTF8(.object(["name": .string(model)]))
            .data(using: .utf8)
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let v = NativeJSONWriter.loads(data), case .object(let o) = v,
              case .array(let caps)? = o["capabilities"] else { return true }
        return caps.contains { $0.string == "vision" }
    }

    /// POST {base}/api/pull {name}（connector.pull_model L395-403，60s 读超时）：
    /// 非 2xx 抛错（raise_for_status 等价）；NDJSON 非空行原样收集。
    public static func liveOllamaPullLines(_ base: String, _ name: String) async throws -> [String] {
        guard let url = URL(string: "\(base)/api/pull") else {
            throw NativeInferenceError.badBase(base)
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 60.0
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = NativeDatabase.dumpsUTF8(.object(["name": .string(name)]))
            .data(using: .utf8)
        let (data, resp) = try await URLSession.shared.data(for: req)
        try ensure2xx(resp, data: data)
        return ndjsonLines(data)
    }

    /// DELETE {base}/api/delete {name}（connector.delete_model L405-408）：
    /// status==200 → true；其余非 2xx → false（不抛）；传输失败抛错。
    public static func liveOllamaDeleteModel(_ base: String, _ name: String) async throws -> Bool {
        guard let url = URL(string: "\(base)/api/delete") else {
            throw NativeInferenceError.badBase(base)
        }
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        req.timeoutInterval = 300
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = NativeDatabase.dumpsUTF8(.object(["name": .string(name)]))
            .data(using: .utf8)
        let (data, resp) = try await URLSession.shared.data(for: req)
        _ = data
        guard let http = resp as? HTTPURLResponse else {
            throw NativeInferenceError.transport("非 HTTP 响应")
        }
        return http.statusCode == 200
    }
}
