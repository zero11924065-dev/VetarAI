//
//  NativeSidecarClient+Panels.swift
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

//  面板注入点都是 `sidecar.client as? XxxPanelClient`——原生客户端必须全员
//  命中 cast。本文件逐个协议实现：全 19 模块走 NativeKernel（注释注明）；
//  历史上未移植模块一行转发 fallback（HTTP），P3-W6 侧车归零后机制删除。
//

import Foundation
import AppKit   // NSWorkspace（openKnowledgeDir 原生实现）

// MARK: - SettingsPanelClient（config 原生；模型清单/CU 探测转发）

extension NativeSidecarClient: SettingsPanelClient {

    /// GET /api/config 等价：get_config()（合并/补写/迁移全保留）。
    public func getConfig() async throws -> SidecarConfig {
        do { return SidecarConfig(storage: try kernel.config.getConfig()) }
        catch { throw mapError(error) }
    }

    /// PUT /api/config 等价：reload_config(patch)。ValueError→400；其他→500「保存配置失败: …」。
    @discardableResult
    public func updateConfig(_ patch: [String: JSONValue]) async throws -> SidecarConfig {
        do {
            let out = SidecarConfig(storage: try kernel.config.reloadConfig(patch: patch))
            // A13（app.py L272）：RESOURCE_INFERENCE / ACTION_UPDATE
            NativeEndpointNotify.change(NativeAppEvents.resourceInference,
                                        NativeAppEvents.actionUpdate)
            return out
        } catch let e as NativeCoreError {
            if case .invalidConfig(let msg) = e { throw SidecarError.httpError(status: 400, detail: msg) }
            throw SidecarError.httpError(status: 500, detail: "保存配置失败: \(msg(of: e))")
        } catch {
            throw SidecarError.httpError(status: 500, detail: "保存配置失败: \(error.localizedDescription)")
        }
    }

    private func msg(of e: NativeCoreError) -> String {
        switch e {
        case .invalidConfig(let m), .io(let m), .database(let m), .notFound(let m), .unprocessable(let m): return m
        }
    }

    /// GET /api/inference/models 等价（P3-W2a 翻原生，同 InferencePanelClient 面）：
    /// 活动后端原生 + MP 并集原生注册表回源（P3-W3a）；backend=model_package
    /// 整端点原生 modelsMP（P3-W6 收口，历史上此分支 HTTP 转发；
    /// 0.7.5 遗留③ / W3 起 modelsMP = MP 注册表 ∪ .vmodel 启用集）。
    public func listInferenceModels() async throws -> [InferenceModelItem] {
        let entries: [InferenceModelEntry]
        if isMPBackendStripped() {
            entries = kernel.inferenceEndpoints.modelsMP()
        } else {
            entries = try await kernel.inferenceEndpoints.models(mpUnion: mpUnionFetcher,
                                                                 vmodelUnion: vmodelUnionFetcher)
        }
        return entries.map {
            InferenceModelItem(name: $0.name, size: $0.size,
                               contextLength: $0.context_length, source: $0.source)
        }
    }

    /// GET /api/computer-use/capabilities 等价（P3-W6 翻原生）：
    /// executor.py check_capabilities 逐行为（NativeCUCapabilities），
    /// 平台探针与 CU 引擎同源（platformAdapter）。
    public func computerUseCapabilities() async throws -> CUCapabilities {
        NativeCUCapabilities.check(adapter: kernel.computerUseEngine.platformAdapter)
    }

    /// GET compact_log 等价（messages 模块原生读）。
    public func compactLog(projectId: String, sessionId: String) async throws -> [CompactLogEntry] {
        do {
            return try kernel.database.loadCompactLog(projectId: projectId, sessionId: sessionId).map { r in
                CompactLogEntry(ts: r.ts ?? "", beforeTokens: r.beforeTokens.map { Int($0) },
                                afterTokens: r.afterTokens.map { Int($0) },
                                archivePath: r.archivePath, error: r.error)
            }
        } catch { throw mapError(error) }
    }
}

// MARK: - ChatPanelClient（config/会话重命名/换模型原生；context-limit/pull P3-W2a 翻原生；流式与编排转发）

extension NativeSidecarClient: ChatPanelClient {

    /// GET /api/config 的 [String: Any] 形态（chat/inference/plugins 共用签名）。
    public func fetchConfig() async throws -> [String: Any] {
        do { return try kernel.config.getConfig().mapValues { $0.anyValue } }
        catch { throw mapError(error) }
    }

    /// GET /api/context/limit 等价（app.py L500-592，P3-W2a 翻原生，P3-W3a MP 面原生）：
    /// ollama 面四级回退（config 懒档→ps→show→262144）原生；openai_compatible →
    /// unsupported 原生；backend=model_package → contextLimitMP（tier→manifest→
    /// unsupported）原生——注意 app.py L528-529 后端判定不 strip，判据同口径。
    public func fetchContextLimit(model: String) async throws -> ContextLimitInfo {
        let cfg = (try? kernel.config.getConfig()) ?? [:]
        if (cfg["inference_backend"]?.string ?? "ollama") == "model_package" {
            return await kernel.inferenceEndpoints.contextLimitMP(model: model)
        }
        return await kernel.inferenceEndpoints.contextLimit(model: model)
    }

    /// PUT /api/sessions/{sid} 等价：rename_session；false → 404「会话不存在」。
    public func renameSession(projectId: String, sessionId: String, title: String) async throws {
        do {
            if try !kernel.database.renameSession(projectId: projectId, sessionId: sessionId, title: title) {
                throw SidecarError.httpError(status: 404, detail: "会话不存在")
            }
        } catch { throw mapError(error) }
    }

    /// DELETE /api/sessions/{sid}?project_id= 等价（app.py L729-756 逐行为，P3-W1a 翻原生）：
    /// 取消关联在飞委派任务（status ∈ (queued, running) 且 session_id 或 parent_session_id
    /// 命中，list_agent_tasks limit=200）→ 有停止则等 1s（执行循环走到下一检查点，
    /// 不再发起新的模型调用）→ delete_session（DB；false → 404「会话不存在」，且 404
    /// 时不得删任何附件文件——清理必须在删除成功之后）→ delete_session_attachments
    /// （FS 清理失败不影响删除结果，附件是副本、DB 记录已删才是主语义）。
    /// ⚠️ 规格偏差记录：端点 docstring（app.py L733）声称「清理该会话挂起的未响应
    /// 授权请求（_auth_pending，防内存泄漏）」，但端点体并未执行该清理——
    /// 按实际行为复刻（不做授权清理），差异记入提交信息。
    @discardableResult
    public func deleteSession(projectId: String, sessionId: String) async throws -> Bool {
        do {
            let tasks = try kernel.database.listAgentTasks(projectId: projectId, limit: 200)
            var stopped = 0
            for t in tasks where (t.status == "queued" || t.status == "running")
                && (t.sessionId == sessionId || t.parentSessionId == sessionId) {
                NativeDelegationEngine.requestDelegationCancel(t.id)
                stopped += 1
            }
            if stopped > 0 { try? await Task.sleep(nanoseconds: 1_000_000_000) }
        } catch { /* stop 失败不影响删除 */ }
        do {
            guard try kernel.database.deleteSession(projectId: projectId, sessionId: sessionId) else {
                throw SidecarError.httpError(status: 404, detail: "会话不存在")
            }
        } catch let e as SidecarError { throw e }
        catch { throw mapError(error) }
        _ = kernel.database.deleteSessionAttachments(projectId: projectId, sessionId: sessionId)
        return true
    }

    /// POST /api/sessions/{sid}/compact 等价（app.py L595-605，P3-W1a 翻原生）：
    /// 面板 body={} → keep_recent=nil（config compact_keep_recent 兜底）、
    /// model 缺省 "qwen3.8"；复用 P2-W4d2 NativeCompactor（流内 compact_auto 同款）；
    /// result.ok=false → 422 result.error（端点 HTTPException 口径）。
    /// 偏差⑧：Python 走 get_inference_connector() 工厂（后端感知），原生固定
    /// kernel.chatConnector（ollama）——与流内 compact_auto 原生路径同口径。
    public func compactSession(projectId: String, sessionId: String) async throws {
        let r = await NativeCompactor.compactSession(
            db: kernel.database, connector: kernel.chatConnector,
            config: { [kernel] in
                (try? kernel.config.getConfig()) ?? NativeConfigStore.defaultConfig
            },
            projectId: projectId, sessionId: sessionId)
        if !r.ok {
            throw SidecarError.httpError(status: 422, detail: r.error ?? "压缩失败")
        }
    }

    /// POST /api/sessions/{sid}/export 等价（app.py L608-633，P3-W1a 翻原生）：
    /// dir 非空 → compactor.export_session_md（目录白名单，400 文案逐字）；
    /// dir 缺省/空串 → exporter.export_session_md 统一目录（含工具步骤摘要；404）。
    public func exportSession(projectId: String, agentId: String, sessionId: String, dir: String?) async throws -> ExportResult {
        do {
            var r = ExportResult()
            if let dir, !dir.isEmpty {
                r.path = try NativeSessionOps.exportSessionToDir(
                    db: kernel.database,
                    config: (try? kernel.config.getConfig()) ?? NativeConfigStore.defaultConfig,
                    projectId: projectId, sessionId: sessionId, dir: dir)
            } else {
                let e = try NativeSessionOps.exportSessionUnified(
                    db: kernel.database,
                    config: (try? kernel.config.getConfig()) ?? NativeConfigStore.defaultConfig,
                    projectId: projectId, sessionId: sessionId, agentId: agentId)
                r.path = e.path
                r.name = e.name
            }
            r.ok = true
            return r
        } catch let e as SidecarError { throw e }
        catch { throw mapError(error) }
    }

    /// POST /api/sessions/{sid}/summarize 等价（app.py L641-693，P3-W1a 翻原生）：
    /// ≤8000 字符非归档消息拼接 → connector chat（中文 prompt 逐字）→
    /// save_session_summary（MD+DB）→ {ok, summary, saved_file}。
    public func summarizeSession(projectId: String, agentId: String, sessionId: String, model: String) async throws -> SummarizeResult {
        do {
            let r = try await NativeSessionOps.summarizeSession(
                db: kernel.database, connector: kernel.chatConnector,
                config: (try? kernel.config.getConfig()) ?? NativeConfigStore.defaultConfig,
                projectId: projectId, sessionId: sessionId, agentId: agentId, model: model)
            var out = SummarizeResult()
            out.ok = true
            out.summary = r.summary
            out.savedFile = r.savedFile
            return out
        } catch let e as SidecarError { throw e }
        catch { throw mapError(error) }
    }

    /// POST /api/attachments/parse 等价（app.py L936-975，P3-W1b 翻原生）：
    /// b64 400 / 10MB 400 / NativeDocParser 提取 / 单件 200k 截断 /
    /// C7 归属齐全才落盘（净化+同名两份保留铁律，save_error 如实不谎称）。
    public func parseAttachment(name: String, contentBase64: String,
                                projectId: String, sessionId: String) async throws -> AttachmentParseResult {
        do {
            return try NativeAttachmentEndpoints.parseChatAttachment(
                name: name, contentBase64: contentBase64,
                projectId: projectId, sessionId: sessionId,
                projectsRoot: kernel.database.projectsRoot)
        } catch let e as SidecarError { throw e }
        catch { throw mapError(error) }
    }

    /// 思考中注入（api_chat_inject L1593-1622，P2-W4d2 原生）：
    /// 422 空 sid/空内容；先落库再入队；仅活流接受（ok:false 原文案不抛错）。
    public func injectMessage(projectId: String, agentId: String,
                              sessionId: String, content: String) async throws -> InjectResult {
        do {
            return try await kernel.chatEndpoints.injectMessage(
                projectId: projectId, agentId: agentId, sessionId: sessionId, content: content)
        } catch { throw mapError(error) }
    }

    /// PUT /api/agents/{pid}/{aid} {model_name} 等价（agents 模块原生更新）。
    public func updateAgentModel(projectId: String, agentId: String, modelName: String) async throws {
        do {
            if try !kernel.database.updateAgentConfig(projectId: projectId, agentId: agentId, modelName: modelName) {
                throw SidecarError.httpError(status: 404, detail: "Agent 不存在")
            }
            // A13（app.py L812，同一端点 api_update_agent）：agent/update
            NativeEndpointNotify.change(NativeAppEvents.resourceAgent,
                                        NativeAppEvents.actionUpdate, projectId: projectId,
                                        extra: ["agent_id": .string(agentId)])
        } catch { throw mapError(error) }
    }

    /// POST /api/ollama/pull 等价（app.py L428-435，P3-W2a 翻原生）：
    /// 能力表 pull=false → 400 逐字（MP/openai 因此无需 HTTP）；NDJSON 行全量收集
    /// 后返回（面板 Void 口径只取成功/失败，事件流在面板层本就不消费）。
    public func pullModel(name: String) async throws {
        _ = try await kernel.inferenceEndpoints.pull(name: name)
    }

    /// inference_backend 键读 config（原生）。
    public func fetchInferenceBackend() async throws -> String {
        do { return try kernel.config.getConfig()["inference_backend"]?.string ?? "" }
        catch { throw mapError(error) }
    }

    /// POST /api/knowledge/transfer 等价（app.py L2384-2417，P3-W1b 翻原生）：
    /// scope 白名单 400 → load_messages 挑未归档勾选（查虫K-2：已归档跳过防重复条目；
    /// 全跳过 → 404）→ **role**：content 拼正文（空白内容跳过；全文空 422）→
    /// 标题用户指定 > 首条前 20 字 → add_entry（nil → 500；嵌入可用即触发，
    /// 不可用静默降级）→ archive_messages 按请求**全量** id 标记（含已归档幂等
    /// 重标，rowcount 如实回传）。端点无 SSE notify（逐字）。
    public func transferToWarehouse(_ req: KnowledgeTransferRequest) async throws -> KnowledgeTransferResult {
        guard req.scope == "project" || req.scope == "global" else {
            throw SidecarError.httpError(status: 400, detail: "scope 必须是 project 或 global")
        }
        do {
            let msgs = try kernel.database.loadMessages(projectId: req.project_id,
                                                        sessionId: req.session_id)
            let idSet = Set(req.message_ids.map { Int64($0) })
            let picked = msgs.filter { idSet.contains($0.id) && !$0.archived }
            guard !picked.isEmpty else {
                throw SidecarError.httpError(status: 404,
                                             detail: "未找到指定消息（或消息已在知识仓库中）")
            }
            var bodyLines: [String] = []
            for m in picked {
                let content = (m.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !content.isEmpty { bodyLines.append("**\(m.role)**：\(content)") }
            }
            let body = bodyLines.joined(separator: "\n\n")
            guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw SidecarError.httpError(status: 422, detail: "勾选的消息无文本内容")
            }
            // 标题：用户指定 > 首条前 20 字（Python strip / [:20] code point 口径——
            // 按 unicodeScalars 截，同 NativeStreamEndpoints 偏差⑥）
            var title = (req.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if title.isEmpty {
                let first = picked.first(where: {
                    !(($0.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)).isEmpty
                })?.content ?? ""
                title = String(first.unicodeScalars.prefix(20))
                if title.isEmpty { title = "未命名" }
            }
            guard let entry = kernel.knowledge.addEntry(
                scope: req.scope, projectId: req.scope == "project" ? req.project_id : nil,
                title: title, body: body, category: req.category,
                keywords: req.keywords, source: "chat") else {
                throw SidecarError.httpError(status: 500,
                                             detail: "知识条目写入失败（目录不可用）")
            }
            // 归档消息（脱离模型上下文）：按请求全量 id（Python 传 req.message_ids 原文）
            let archived = try kernel.database.archiveMessages(
                projectId: req.project_id, messageIds: req.message_ids.map { Int64($0) })
            var r = KnowledgeTransferResult()
            r.ok = true
            r.title = title
            r.archived = archived
            return r
        } catch let e as SidecarError { throw e }
        catch { throw mapError(error) }
    }
}

// MARK: - ProjectsPanelClient（重命名/删除原生；导出/开目录转发）

extension NativeSidecarClient: ProjectsPanelClient {

    /// PUT /api/projects/{pid} 等价：false → 404「项目不存在」。
    public func renameProject(projectId: String, name: String) async throws {
        do {
            if try !kernel.database.renameProject(projectId, name: name) {
                throw SidecarError.httpError(status: 404, detail: "项目不存在")
            }
            // A13（app.py L825）：project/update
            NativeEndpointNotify.change(NativeAppEvents.resourceProject,
                                        NativeAppEvents.actionUpdate, projectId: projectId)
        } catch { throw mapError(error) }
    }

    /// DELETE /api/projects/{pid} 等价（端点恒 200，无引擎编排——原生安全）。
    public func deleteProject(projectId: String) async throws {
        do {
            _ = try kernel.database.deleteProject(projectId)
            // A13（app.py L320）：project/delete
            NativeEndpointNotify.change(NativeAppEvents.resourceProject,
                                        NativeAppEvents.actionDelete, projectId: projectId)
        } catch { throw mapError(error) }
    }

    /// POST /api/projects/{pid}/export-workgroup 等价（P3-W6 翻原生）：
    /// exporter.py export_workgroup_json 逐行为（NativeWorkgroupExport），
    /// 项目不存在 → 404 逐字。
    public func exportWorkgroup(projectId: String) async throws -> WorkgroupExportResult {
        let cfg = (try? kernel.config.getConfig()) ?? [:]
        let r = try NativeWorkgroupExport.export(db: kernel.database, config: cfg,
                                                 projectId: projectId)
        return WorkgroupExportResult(ok: true, path: r.path, name: r.name)
    }

    /// POST /api/projects/open-working-dir 等价（app.py L2704-2730，P3-W6 翻原生）：
    /// 404/400 校验链逐字；原生 NSWorkspace 打开（macOS 恒真分支——非 macOS/超时
    /// ok:false 分支对原生 app 不适用，同 openKnowledgeDir 先例）。
    public func openWorkingDir(projectId: String) async throws -> OpenWorkingDirResult {
        guard let proj = try kernel.database.getProject(projectId) else {
            throw SidecarError.httpError(status: 404, detail: "项目不存在")
        }
        guard !proj.workingDir.isEmpty else {
            throw SidecarError.httpError(status: 400, detail: "该项目未设置工作目录")
        }
        let dir = (proj.workingDir as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else {
            throw SidecarError.httpError(status: 400, detail: "工作目录不存在：\(dir)")
        }
        let ok = await MainActor.run { NSWorkspace.shared.open(URL(fileURLWithPath: dir)) }
        return ok ? OpenWorkingDirResult(ok: true, dir: dir, detail: nil)
                  : OpenWorkingDirResult(ok: false, dir: dir, detail: "打开失败（NSWorkspace 拒绝）")
    }
}

// MARK: - IndependentAgentsPanelClient（全量原生：ia-<id> 命名空间）

extension NativeSidecarClient: IndependentAgentsPanelClient {

    public func listIndependentAgents() async throws -> [IndependentAgent] {
        do {
            return try kernel.database.listIndependentAgents().map { r in
                IndependentAgent(id: r.id, name: r.name, role: r.role,
                                 system_prompt: r.systemPrompt, model_name: r.modelName,
                                 created_at: r.createdAt)
            }
        } catch { throw mapError(error) }
    }

    /// POST /api/independent-agents 等价：名称 strip 后空 → 422。
    @discardableResult
    public func createIndependentAgent(name: String, modelName: String?, systemPrompt: String?) async throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            throw SidecarError.httpError(status: 422, detail: "名称不能为空")
        }
        do {
            let aid = try kernel.database.addIndependentAgent(name: trimmed, systemPrompt: systemPrompt, modelName: modelName)
            // A13（app.py L343）：agent/create 带 agent_id（无 project_id）
            NativeEndpointNotify.change(NativeAppEvents.resourceAgent,
                                        NativeAppEvents.actionCreate,
                                        extra: ["agent_id": .string(aid)])
            return aid
        } catch { throw mapError(error) }
    }

    /// PUT /api/independent-agents/{aid} 等价：无有效更新 → 404。
    public func updateIndependentAgent(agentId: String, update: IndependentAgentUpdateRequest) async throws {
        do {
            let ok = try kernel.database.updateIndependentAgent(
                agentId, name: update.name, systemPrompt: update.system_prompt, modelName: update.model_name)
            if !ok {
                throw SidecarError.httpError(status: 404, detail: "独立 Agent 不存在或无有效更新字段")
            }
            // A13（app.py L356）：agent/update
            NativeEndpointNotify.change(NativeAppEvents.resourceAgent,
                                        NativeAppEvents.actionUpdate,
                                        extra: ["agent_id": .string(agentId)])
        } catch { throw mapError(error) }
    }

    /// DELETE /api/independent-agents/{aid} 等价：false → 404。
    public func deleteIndependentAgent(agentId: String) async throws {
        do {
            if try !kernel.database.deleteIndependentAgent(agentId) {
                throw SidecarError.httpError(status: 404, detail: "独立 Agent 不存在")
            }
            // A13（app.py L363）：agent/delete
            NativeEndpointNotify.change(NativeAppEvents.resourceAgent,
                                        NativeAppEvents.actionDelete,
                                        extra: ["agent_id": .string(agentId)])
        } catch { throw mapError(error) }
    }
}

// MARK: - InferencePanelClient / ModelPacksPanelClient
// （config 原生；status/models/delete 翻原生 P3-W2a；模型包管理面翻原生 P3-W3a；
//   events/stream 客户端翻原生 P3-W6，偏差⑦收口）

extension NativeSidecarClient: InferencePanelClient, ModelPacksPanelClient {

    /// PUT /api/config 的 [String: Any] 形态（inference/modelpacks/plugins 共用签名）。
    public func putConfig(_ patch: [String: Any]) async throws {
        var jpatch: [String: JSONValue] = [:]
        for (k, v) in patch { jpatch[k] = JSONValue(anyValue: v) ?? .null }
        _ = try await updateConfig(jpatch)
    }

    // ── P3-W2a 推理端点面翻原生（规格：app.py L428-592；装配 NativeInferenceEndpointAssembly）──

    /// backend=model_package 判据（status/models 转发用；routing.py _backend() 带 strip 口径）。
    func isMPBackendStripped() -> Bool {
        let cfg = (try? kernel.config.getConfig()) ?? [:]
        return (cfg["inference_backend"]?.string ?? "ollama")
            .trimmingCharacters(in: .whitespaces) == "model_package"
    }

    /// GET /api/inference/status 等价（app.py L446-472，P3-W2a 翻原生）：
    /// ollama/openai 面原生（8s 探活 + 能力表）；P3-W3a 起 backend=model_package
    /// 面同样原生（caps=MP 能力表、base_url=驱动动态端口、online 恒 true——
    /// 注册表读无失败项）。
    public func fetchInferenceStatus() async throws -> InferenceStatusInfo {
        if isMPBackendStripped() {
            return kernel.inferenceEndpoints.statusMP()
        }
        return await kernel.inferenceEndpoints.status()
    }

    /// GET /api/inference/models 等价（app.py L474-498，P3-W2a 翻原生）：
    /// 活动后端原生 + MP 并集经 mpUnionFetcher 原生注册表读（P3-W3a）；
    /// backend=model_package（routing 退化模式，并集=全 MP ∪ .vmodel 启用集——
    /// 0.7.5 遗留③ / W3 补齐）原生 modelsMP。
    public func fetchInferenceModels() async throws -> [InferenceModelEntry] {
        if isMPBackendStripped() {
            return kernel.inferenceEndpoints.modelsMP()
        }
        return try await kernel.inferenceEndpoints.models(mpUnion: mpUnionFetcher,
                                                          vmodelUnion: vmodelUnionFetcher)
    }

    /// DELETE /api/ollama/models/{name} 等价（app.py L437-444，P3-W2a 翻原生）：
    /// 能力表 delete=false → 400 逐字（MP/openai 因此无需 HTTP）；deleted:false 不抛错
    /// （端点 200 {"deleted": false} 口径，面板 Void 忽略布尔）。
    public func deleteModel(name: String) async throws {
        _ = try await kernel.inferenceEndpoints.delete(name: name)
    }

    /// GET /api/events/stream 等价（P3-W6 翻原生，偏差⑦收口）：直返
    /// NativeAppEventsEndpoint.stream——connected 握手带 seq → NativeAppEvents
    /// 增量（_subscribed/_idle 过滤、_bus_closed 收尾逐行为）；事件名 raw 分发
    /// 口径与 HTTP 侧一致（面板按 SSEEvent.event 原始名分发，协议零改动）。
    public func appEventsStream(since: Int) -> AsyncThrowingStream<SSEEvent, Error> {
        NativeAppEventsEndpoint.stream(since: since)
    }

    // ── P3-W3a 模型包端点面翻原生（规格：app.py L2746-2900；装配 NativeModelPackEndpoints）──

    /// GET /api/model-packs 等价（L2781-2784）：注册表+磁盘探测列表。
    public func listModelPacks() async throws -> ModelPackListResponse {
        kernel.modelPackEndpoints.listPacks()
    }

    /// GET /api/model-packs/catalog 等价（L2787-2819）：逐源合并 + 去重 + 标注；
    /// rawEntries 原样保留可选键（context_length/sample_rate 等，HTTP 同款口径）。
    public func fetchModelPackCatalog() async throws -> (catalog: ModelPackCatalogResponse,
                                                         rawEntries: [String: [String: Any]]) {
        await kernel.modelPackEndpoints.catalog()
    }

    /// POST /api/model-packs/install 等价（L2822-2853）：400/409 链逐字；
    /// 生命周期事件由下载器发射（accepted 立即返回，进度走原生总线 SSE）。
    public func installModelPack(packId: String, catalogEntry: [String: Any]) async throws {
        var j: [String: JSONValue] = [:]
        for (k, v) in catalogEntry { j[k] = JSONValue(anyValue: v) ?? .null }
        try kernel.modelPackEndpoints.install(packId: packId, catalogEntry: j)
    }

    /// POST /api/model-packs/cancel 等价（L2856-2864）：无进行中任务 404 逐字。
    public func cancelModelPackDownload(packId: String) async throws {
        try await kernel.modelPackEndpoints.cancel(packId: packId)
    }

    /// DELETE /api/model-packs/{pack_id} 等价（L2867-2883）：在飞先取消 →
    /// 回收运行时（chat 面 llama stop；ASR 面留 W3b）→ 删目录+注册表。
    public func deleteModelPack(packId: String) async throws {
        try await kernel.modelPackEndpoints.deletePack(packId)
    }

    /// POST /api/model-packs/{pack_id}/toggle 等价（L2886-2900）：禁用立即回收运行时。
    public func toggleModelPack(packId: String, enabled: Bool) async throws {
        try await kernel.modelPackEndpoints.toggle(packId: packId, enabled: enabled)
    }
}

// MARK: - 知识库/记忆原生 + 技能原生（P2-W1：store_knowledge.py 移植；
//   P3-W1b：skills_mgr 面板端点面翻原生——管理器本体 P2-W4c 已原生）
//
//  A13 说明：原生写操作不发 _notify_change（SSE 流由侧车持有）——面板 VM 写后自行
//  重拉（W3 设计如此），聊天循环侧车改知识库的事件仍经 HTTP SSE 送达，无回归。

extension NativeSidecarClient: KnowledgePanelClient {
    /// GET /api/projects/{pid}/knowledge 等价（app.py L2055：无项目存在性校验，幽灵项目 → []）。
    public func listKnowledge(projectId: String) async throws -> [KnowledgeFileItem] {
        kernel.knowledge.listKnowledge(projectId).map {
            KnowledgeFileItem(name: $0.name, size: $0.size, enabled: $0.enabled)
        }
    }

    /// GET …/knowledge/{name} 等价：nil → 404（L2061-2062）。
    public func readKnowledge(projectId: String, name: String) async throws -> KnowledgeFileContent {
        guard let content = kernel.knowledge.readKnowledge(projectId, name) else {
            throw SidecarError.httpError(status: 404, detail: "知识文件不存在或文件名非法")
        }
        return KnowledgeFileContent(name: name, content: content)
    }

    /// PUT …/knowledge 等价（L2069-2077）：strip 后非 .md → 400；写失败 → 400。
    public func writeKnowledge(projectId: String, name: String, content: String) async throws {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasSuffix(".md") else {
            throw SidecarError.httpError(status: 400, detail: "文件名必须以 .md 结尾")
        }
        guard kernel.knowledge.writeKnowledge(projectId, trimmed, content) else {
            throw SidecarError.httpError(status: 400, detail: "保存失败（文件名非法或项目工作目录不可写）")
        }
        // A13（app.py L2076）：knowledge/update 带 name
        NativeEndpointNotify.change(NativeAppEvents.resourceKnowledge,
                                    NativeAppEvents.actionUpdate, projectId: projectId,
                                    extra: ["name": .string(trimmed)])
    }

    /// DELETE …/knowledge/{name} 等价：false → 404（L2081-2082）。
    public func deleteKnowledge(projectId: String, name: String) async throws {
        guard kernel.knowledge.deleteKnowledge(projectId, name) else {
            throw SidecarError.httpError(status: 404, detail: "知识文件不存在或文件名非法")
        }
        // A13（app.py L2083）：knowledge/delete 带 name
        NativeEndpointNotify.change(NativeAppEvents.resourceKnowledge,
                                    NativeAppEvents.actionDelete, projectId: projectId,
                                    extra: ["name": .string(name)])
    }

    /// POST …/toggle 等价：nil → 400（L2089-2090）。
    @discardableResult
    public func toggleKnowledge(projectId: String, name: String) async throws -> String {
        guard let newName = kernel.knowledge.toggleKnowledge(projectId, name) else {
            throw SidecarError.httpError(status: 400, detail: "切换失败（文件不存在或同名冲突）")
        }
        // A13（app.py L2091）：knowledge/update 带新名
        NativeEndpointNotify.change(NativeAppEvents.resourceKnowledge,
                                    NativeAppEvents.actionUpdate, projectId: projectId,
                                    extra: ["name": .string(newName)])
        return newName
    }

    /// GET /api/memory 等价（L2094-2098）：scope 非法 → 400；projectId 空串 → nil。
    public func readMemory(scope: String, projectId: String?) async throws -> MemoryContent {
        guard scope == "global" || scope == "project" else {
            throw SidecarError.httpError(status: 400, detail: "scope 必须是 global 或 project")
        }
        let pid = projectId.flatMap { $0.isEmpty ? nil : $0 }
        return MemoryContent(scope: scope, content: kernel.knowledge.readMemory(scope, pid))
    }

    /// PUT /api/memory 等价（L2105-2112）：scope 非法 → 400；写失败 → 400。
    public func writeMemory(scope: String, projectId: String?, content: String) async throws {
        guard scope == "global" || scope == "project" else {
            throw SidecarError.httpError(status: 400, detail: "scope 必须是 global 或 project")
        }
        let pid = projectId.flatMap { $0.isEmpty ? nil : $0 }
        guard kernel.knowledge.writeMemory(scope, content, pid) else {
            throw SidecarError.httpError(status: 400, detail: "保存失败（项目记忆需要有效的项目工作目录）")
        }
        // A13（app.py L2111）：knowledge/update（project_id 空 → None）
        NativeEndpointNotify.change(NativeAppEvents.resourceKnowledge,
                                    NativeAppEvents.actionUpdate, projectId: pid)
    }

    // ── 技能（P3-W1b 翻原生：skills_mgr/manager.py 全量 + app.py L2114-2164 端点面）──
    //
    //  ⚠️ 技能写端点无 SSE notify（app.py L2114-2164 逐字核对：七个端点均不调
    //  _notify_change）——面板 VM 写后自行 refresh 重拉，原生侧同样不发。

    /// GET /api/skills 等价（L2114-2116）：[{name, dir_name, description, enabled, path}]。
    public func listSkills() async throws -> [SkillItem] {
        kernel.skillsManager.listSkills().map {
            SkillItem(name: $0.name, dir_name: $0.dirName,
                      description: $0.skillDescription, enabled: $0.enabled, path: $0.path)
        }
    }

    /// GET /api/skills/{name} 等价（L2136-2141）：nil → 404「技能不存在」。
    public func readSkill(dirName: String) async throws -> SkillDetail {
        guard let d = kernel.skillsManager.readSkillDetail(dirName) else {
            throw SidecarError.httpError(status: 404, detail: "技能不存在")
        }
        return SkillDetail(name: d.name, dir_name: d.dirName,
                           description: d.skillDescription, enabled: d.enabled,
                           content: d.content)
    }

    /// POST /api/skills 等价（L2124-2128）：非法名 → 400 原文案。
    public func createSkill(name: String, description: String, body: String, enabled: Bool) async throws {
        guard kernel.skillsManager.createOrUpdateSkill(name, description: description,
                                                       body: body, enabled: enabled) else {
            throw SidecarError.httpError(status: 400, detail: "技能名非法（限字母/数字/中文/-/_，≤64 字符）")
        }
    }

    /// PUT /api/skills/{name} 等价（L2130-2134）：失败 → 400「更新失败」。
    public func updateSkill(dirName: String, description: String, body: String, enabled: Bool) async throws {
        guard kernel.skillsManager.createOrUpdateSkill(dirName, description: description,
                                                       body: body, enabled: enabled) else {
            throw SidecarError.httpError(status: 400, detail: "更新失败")
        }
    }

    /// DELETE /api/skills/{name} 等价（L2143-2147）：false → 404「技能不存在或名称非法」。
    public func deleteSkill(dirName: String) async throws {
        guard kernel.skillsManager.deleteSkill(dirName) else {
            throw SidecarError.httpError(status: 404, detail: "技能不存在或名称非法")
        }
    }

    /// POST /api/skills/{name}/toggle 等价（L2149-2154）：nil → 400「切换失败（技能不存在）」。
    @discardableResult
    public func toggleSkill(dirName: String) async throws -> Bool {
        guard let newState = kernel.skillsManager.toggleSkill(dirName) else {
            throw SidecarError.httpError(status: 400, detail: "切换失败（技能不存在）")
        }
        return newState
    }

    /// POST /api/skills/install 等价（L2159-2164）：ok=false → 400 result.error
    /// （缺省「安装失败」）。安装通道复用 W3a NativeToolInstall.installSkillFromRepo
    /// （本地目录直拷 / git clone --depth 1 剥代理环境 120s 超时，guard 唯一漏斗契约）。
    public func installSkill(url: String) async throws {
        do {
            let ctx = NativeToolContext.live(config: kernel.config, guard: kernel.networkGuard)
            let res = try await NativeToolInstall.installSkillFromRepo(url, context: ctx)
            guard res["ok"]?.bool == true else {
                throw SidecarError.httpError(status: 400,
                                             detail: res["error"]?.string ?? "安装失败")
            }
        } catch let e as SidecarError { throw e }
        catch { throw mapError(error) }
    }
}

// MARK: - 知识仓库原生（P2-W1：warehouse.py 移植 + CoreML 嵌入内生化）
//
//  端点语义对照（app.py L2556-2698）：
//    · entries/search 读取前先 prune_missing 对账（外部删除不命中）
//    · search 的 mode 非法兜底 hybrid、limit clamp 1~100
//    · search 的 scope 透传（缺省/空 = 全部；panel 只发 project/global）
//    · 原生嵌入不可用时 semantic 自动降级关键词（hybridSearch 内建，逐字对齐）

extension NativeSidecarClient: WarehousePanelClient {

    /// GET /api/knowledge/entries 等价（L2556-2560）。
    public func listWarehouseEntries(scope: String, projectId: String?) async throws -> [WarehouseEntry] {
        kernel.knowledge.pruneMissing()
        return kernel.knowledge
            .listEntries(scope: scope.isEmpty ? nil : scope, projectId: projectId)
            .map(Self.warehouseEntry(_:))
    }

    /// GET /api/knowledge/search 等价（L2563-2572：prune + mode 兜底 + limit clamp）。
    public func searchWarehouse(query: String, scope: String, projectId: String?,
                                mode: String, limit: Int) async throws -> [WarehouseEntry] {
        kernel.knowledge.pruneMissing()
        let m = ["keyword", "semantic", "hybrid"].contains(mode) ? mode : "hybrid"
        let lim = min(max(limit, 1), 100)
        return kernel.knowledge
            .hybridSearch(query, scope: scope.isEmpty ? nil : scope,
                          projectId: projectId, limit: lim, mode: m)
            .map(Self.warehouseEntry(_:))
    }

    /// POST /api/knowledge/inject 等价（L2595-2606）：全失效 → 404。
    public func injectWarehouseEntries(entryIds: [String]) async throws -> String {
        guard let text = kernel.knowledge.injectText(entryIds: entryIds) else {
            throw SidecarError.httpError(status: 404, detail: "未找到任何有效条目")
        }
        return text
    }

    /// NativeKnowledgeEntry → WarehouseEntry（列表无 body/score；检索带——对齐端点差异）。
    private static func warehouseEntry(_ e: NativeKnowledgeEntry) -> WarehouseEntry {
        WarehouseEntry(id: e.id, title: e.title, scope: e.scope,
                       project_id: e.projectId.isEmpty ? nil : e.projectId,
                       category: e.category.isEmpty ? nil : e.category,
                       keywords: e.keywords, source: e.source, file_path: e.filePath,
                       created_at: e.createdAt, body: e.body, score: e.score)
    }
}

extension NativeSidecarClient: WarehouseManagerClient {

    /// GET /api/knowledge/groups 等价（L2623-2643）。
    public func listKnowledgeGroups() async throws -> [KnowledgeGroup] {
        kernel.knowledge.knowledgeGroups().map {
            KnowledgeGroup(scope: $0.scope, project_id: $0.projectId,
                           project_name: $0.projectName, count: $0.count, dir: $0.dir)
        }
    }

    /// GET /api/knowledge/embedding-status 等价（L2575-2588）。
    /// model/model_dir 如实反映原生 CoreML 模型（与侧车 int8 文案不同，面板仅展示）。
    /// 0.5.2 A1：透传 load_state（装载三态），面板「装载中…」分支与轮询靠它驱动。
    public func fetchEmbeddingStatus() async throws -> EmbeddingStatus {
        let s = kernel.knowledge.embeddingStatus()
        return EmbeddingStatus(available: s.available, model: s.model,
                               model_dir: s.modelDir.isEmpty ? nil : s.modelDir,
                               entries_total: s.entriesTotal, entries_embedded: s.entriesEmbedded,
                               load_state: s.loadState)
    }

    /// POST /api/knowledge/rebuild-index 等价（L2609-2620）。
    /// CPU 密集 → 后台线程（对齐端点 run_in_executor 口径，防阻塞调用方 actor）。
    @discardableResult
    public func rebuildKnowledgeIndex() async throws -> KnowledgeRebuildResult {
        let store = kernel.knowledge
        let n = try await Task.detached(priority: .userInitiated) { store.rebuildIndex() }.value
        return KnowledgeRebuildResult(ok: true, entries: n)
    }

    /// POST /api/knowledge/open-dir 等价（L2651-2667）：
    /// 原生 NSWorkspace 打开（macOS 恒真分支；非 macOS/超时 ok:false 分支对原生 app 不适用）。
    /// scope 无效 → 400（白名单校验语义保留：只开知识目录，不接受任意路径）。
    public func openKnowledgeDir(scope: String, projectId: String?) async throws -> KnowledgeOpenDirResult {
        guard let kdir = kernel.knowledge.scopeDir(scope, projectId) else {
            throw SidecarError.httpError(status: 400, detail: "无效的作用域或项目")
        }
        try? FileManager.default.createDirectory(at: kdir, withIntermediateDirectories: true)
        let ok = await MainActor.run { NSWorkspace.shared.open(kdir) }
        return ok ? KnowledgeOpenDirResult(ok: true, dir: kdir.path)
                  : KnowledgeOpenDirResult(ok: false, dir: kdir.path, detail: "打开失败（NSWorkspace 拒绝）")
    }

    /// POST /api/knowledge/import-files 等价（L2682-2698）：
    /// on_conflict 白名单 400 逐字；IO+解析+嵌入 CPU/IO 密集 → 后台线程。
    public func importKnowledgeFiles(scope: String, projectId: String?, paths: [String],
                                     onConflict: String) async throws -> KnowledgeImportResult {
        guard ["ask", "overwrite", "rename", "skip"].contains(onConflict) else {
            throw SidecarError.httpError(
                status: 400,
                detail: "无效的 on_conflict: \(onConflict)（可用 ask/overwrite/rename/skip）")
        }
        let store = kernel.knowledge
        let r = await Task.detached(priority: .userInitiated) {
            store.importFiles(scope: scope, projectId: projectId, sources: paths, onConflict: onConflict)
        }.value
        return KnowledgeImportResult(
            imported: r.imported, failed: r.failed, skipped: r.skipped,
            conflicts: r.conflicts,
            details: r.details.map {
                KnowledgeImportDetail(name: $0.name, status: $0.status,
                                      reason: $0.reason, conflict_resolved: $0.conflictResolved)
            })
    }
}

// MARK: - PluginsPanelClient（P3-W5 全量原生：app.py L844-913 八端点；
//   装配 kernel.pluginEndpoints——NativePluginStore 管理面（state/notes 两 JSON
//   与 Python 同目录同格式，既有插件直接可读）+ ADR-0046 P-A python3 子进程桥
//   （hook 手动触发面板零感知）。错误已由端点层包装成 SidecarError.httpError，
//   与 HTTP 层同形，面板 VM 零改动）

extension NativeSidecarClient: PluginsPanelClient {
    /// GET /api/plugins 等价（L853-861：两态合并 + entry_point/hooks 缺省补齐）。
    public func listPlugins() async throws -> [SidecarPlugin] {
        do {
            return try kernel.pluginEndpoints.list().map { item in
                guard let name = item["name"]?.string, !name.isEmpty else {
                    throw SidecarError.decodeFailed("SidecarPlugin.name 缺失")
                }
                return SidecarPlugin(name: name,
                                     version: item["version"]?.string,
                                     entry_point: item["entry_point"]?.string,
                                     hooks: item["hooks"]?.stringArray,
                                     path: item["path"]?.string,
                                     enabled: item["enabled"]?.bool,
                                     note: item["note"]?.string,
                                     description: item["description"]?.string)
            }
        } catch let e as SidecarError { throw e } catch { throw mapError(error) }
    }

    /// POST /api/plugins/install 等价（L844-851：成功 A13 create；ANY 失败 400）。
    @discardableResult
    public func installPlugin(repoUrl: String) async throws -> PluginInstallResult {
        do {
            let r = try await kernel.pluginEndpoints.install(repoUrl: repoUrl)
            // TSX 成功提示用 data.name / data.version；name 缺失按空串（同 HTTP 口径）
            return PluginInstallResult(name: r["name"]?.string ?? "",
                                       version: r["version"]?.string)
        } catch let e as SidecarError { throw e } catch { throw mapError(error) }
    }

    /// DELETE /api/plugins/{name} 等价（L863-869：404 逐字 + A13 delete）。
    public func uninstallPlugin(name: String) async throws {
        do { _ = try kernel.pluginEndpoints.uninstall(name: name) }
        catch let e as SidecarError { throw e } catch { throw mapError(error) }
    }

    /// POST /api/plugins/{name}/toggle 等价（L871-878：服务端翻转语义——
    /// 请求体 enabled 字段 Python 端点从不读取，原生同口径忽略）。
    @discardableResult
    public func togglePlugin(name: String, enabled: Bool) async throws -> Bool {
        do { return try kernel.pluginEndpoints.toggle(name: name) }
        catch let e as SidecarError { throw e } catch { throw mapError(error) }
    }

    /// PUT /api/plugins/{name}/note 等价（L888-893：空串=清除 + A13 update）。
    @discardableResult
    public func setPluginNote(name: String, note: String) async throws -> String {
        kernel.pluginEndpoints.setNote(name: name, note: note)
    }

    /// POST /api/plugins/{name}/hooks/{hook} 等价（L895-905：403/404 逐字 +
    /// python3 子进程桥执行；body 固定 agent_context 对齐 TSX）。
    public func triggerPluginHook(plugin: String, hook: String) async throws -> [String: Any] {
        do {
            let r = try await kernel.pluginEndpoints.triggerHook(
                plugin: plugin, hook: hook,
                agentContext: ["trigger": .string("manual"), "source": .string("plugin_panel")])
            return r.mapValues { $0.anyValue }
        } catch let e as SidecarError { throw e } catch { throw mapError(error) }
    }
}

// MARK: - CuMacroPanelClient（P3-W4 全量原生：app.py L2453-2552 八端点；
//   装配 kernel.cuMacroEndpoints——NativeCUMacroStore 双模式录制 +
//   NativeUserRecorder 系统级捕获 + 「输入监控」TCC 主体 = 原生 app 自身。
//   错误已由端点层包装成 SidecarError.httpError，与 HTTP 层同形，面板 VM 零改动）

extension NativeSidecarClient: CuMacroPanelClient {
    /// GET /api/cu-macros 等价（L2453-2462）。
    public func listCuMacros() async throws -> CuMacroListState {
        kernel.cuMacroEndpoints.list()
    }
    /// GET /api/cu-macros/user-record/permission 等价（L2465-2471）。
    public func cuUserRecordPermission() async throws -> CuUserRecordPermission {
        kernel.cuMacroEndpoints.userRecordPermission()
    }
    /// POST /api/cu-macros/user-record/permission/request 等价（L2474-2480）。
    public func requestCuUserRecordPermission() async throws -> CuUserRecordPermission {
        kernel.cuMacroEndpoints.requestUserRecordPermission()
    }
    /// POST /api/cu-macros/record/start 等价（L2483-2499；403/409/422 映射逐字）。
    public func startCuMacroRecording(name: String, mode: String?) async throws -> String {
        try kernel.cuMacroEndpoints.recordStart(name: name, mode: mode)
    }
    /// POST /api/cu-macros/record/stop 等价（L2502-2516；0 步契约 + A13 create）。
    public func stopCuMacroRecording() async throws -> CuMacroStopResult {
        try kernel.cuMacroEndpoints.recordStop()
    }
    /// POST /api/cu-macros/{mid}/replay 等价（L2519-2532；404/409/422 映射逐字）。
    public func replayCuMacro(macroId: String) async throws -> String {
        try kernel.cuMacroEndpoints.replay(macroId: macroId)
    }
    /// GET /api/cu-macros/replays/{run_id} 等价（L2535-2542）。
    public func cuMacroReplayStatus(runId: String) async throws -> CuReplayRun {
        try kernel.cuMacroEndpoints.replayStatus(runId: runId)
    }
    /// DELETE /api/cu-macros/{mid} 等价（L2545-2552；404 + A13 delete）。
    public func deleteCuMacro(macroId: String) async throws {
        try kernel.cuMacroEndpoints.deleteMacro(macroId: macroId)
    }
    /// 全程审计聚合（0.7.4 W5 原生加成只读面；内存运行记录 RUNS_KEPT=50 口径）。
    public func cuMacroAuditSummary() async throws -> [CuMacroAuditEntry] {
        kernel.cuMacroEndpoints.auditSummary()
    }
}

// MARK: - RoundtablePanelClient（P2-W4d2 全量原生：app.py L1855-2038 端点面 +
//   roundtable.py 执行内核 W4d1 已建；圆桌无 SSE——面板 5s 轮询以 DB 为唯一真相源）

extension NativeSidecarClient: RoundtablePanelClient {

    /// GET /api/projects/{pid}/roundtables 等价（L1941-1947）：limit 钳 max(1, min(limit, 100))。
    public func listRoundtables(projectId: String, limit: Int) async throws -> [Roundtable] {
        do {
            let lim = max(1, min(limit, 100))
            return try kernel.database.listRoundtables(projectId: projectId, limit: lim)
                .map { NativeRoundtableEndpoints.rowToPanel($0) }
        } catch { throw mapError(error) }
    }

    /// POST /api/projects/{pid}/roundtables 等价（L1855-1939）：附件预处理 400 链 →
    /// 引擎创建并执行第一轮（NativeRoundtableError → 400 原文案）→ 附件落盘（失败静默）。
    /// vision_parse_attachments 图片视觉识别 P3-W1b 已接管（_vision_parse 逐行为：
    /// 固定 ollama connector + config default_model + prompt 逐字 + 失败空串仅标注）。
    @discardableResult
    public func createRoundtable(projectId: String, request: RoundtableCreateRequest) async throws -> Roundtable {
        do {
            let cfg = (try? kernel.config.getConfig()) ?? NativeConfigStore.defaultConfig
            let visionProbe = NativeRoundtableEndpoints.visionProbeIfEnabled(
                config: cfg, connector: kernel.chatConnector)
            var (metas, files) = try await NativeRoundtableEndpoints.preprocessAttachments(
                request.attachments, visionProbe: visionProbe)
            let row = try await kernel.roundtableEngine.createAndStart(
                projectId: projectId, topic: request.topic, agentIds: request.agent_ids,
                moderator: request.moderator, moderatorAgentId: request.moderator_agent_id,
                maxRounds: request.max_rounds,
                attachments: metas.isEmpty ? nil : metas)
            NativeRoundtableEndpoints.persistAttachmentFiles(
                db: kernel.database, projectId: projectId, rtId: row.id,
                metas: &metas, files: files)
            // 落盘路径写回后重取行（attachments 列已含 saved_path；失败则沿用内存行）
            let final = try kernel.database.getRoundtable(projectId: projectId, rtId: row.id) ?? row
            return NativeRoundtableEndpoints.rowToPanel(final)
        } catch let e as SidecarError { throw e }
        catch let e as NativeRoundtableError {
            throw SidecarError.httpError(status: 400, detail: e.message)
        } catch { throw mapError(error) }
    }

    /// GET /api/roundtables/{rtid} 等价（L1959-1968）：404「圆桌不存在」+ messages 随行
    /// （附件正文不回传——面板模型不带 text 字段）。
    public func getRoundtable(projectId: String, rtId: String) async throws -> Roundtable {
        do {
            guard let row = try kernel.database.getRoundtable(projectId: projectId, rtId: rtId) else {
                throw SidecarError.httpError(status: 404, detail: "圆桌不存在")
            }
            let msgs = try kernel.database.listRoundtableMessages(projectId: projectId, rtId: rtId)
            return NativeRoundtableEndpoints.rowToPanel(row, messages: msgs)
        } catch let e as SidecarError { throw e }
        catch { throw mapError(error) }
    }

    /// POST .../continue 等价（L2001-2012）：404 → 非 waiting_user 400 原文案 → 引擎续轮。
    public func continueRoundtable(projectId: String, rtId: String) async throws {
        do {
            guard let rt = try kernel.database.getRoundtable(projectId: projectId, rtId: rtId) else {
                throw SidecarError.httpError(status: 404, detail: "圆桌不存在")
            }
            guard rt.status == "waiting_user" else {
                throw SidecarError.httpError(status: 400,
                                             detail: "当前状态（\(rt.status)）不允许继续")
            }
            try await kernel.roundtableEngine.continueRoundtable(projectId: projectId, rtId: rtId)
        } catch let e as SidecarError { throw e }
        catch let e as NativeRoundtableError {
            throw SidecarError.httpError(status: 400, detail: e.message)
        } catch { throw mapError(error) }
    }

    /// POST .../finish 等价（L2014-2025）：404 → 仅 waiting_user/confirm_end → 引擎总结。
    public func finishRoundtable(projectId: String, rtId: String) async throws {
        do {
            guard let rt = try kernel.database.getRoundtable(projectId: projectId, rtId: rtId) else {
                throw SidecarError.httpError(status: 404, detail: "圆桌不存在")
            }
            guard rt.status == "waiting_user" || rt.status == "confirm_end" else {
                throw SidecarError.httpError(status: 400,
                                             detail: "当前状态（\(rt.status)）不允许结束")
            }
            try await kernel.roundtableEngine.finishRoundtable(projectId: projectId, rtId: rtId)
        } catch let e as SidecarError { throw e }
        catch let e as NativeRoundtableError {
            throw SidecarError.httpError(status: 400, detail: e.message)
        } catch { throw mapError(error) }
    }

    /// POST .../stop 等价（L2027-2038）：404 → 终态 400 原文案 → 置取消标志（检查点中止）。
    public func stopRoundtable(projectId: String, rtId: String) async throws {
        do {
            guard let rt = try kernel.database.getRoundtable(projectId: projectId, rtId: rtId) else {
                throw SidecarError.httpError(status: 404, detail: "圆桌不存在")
            }
            guard rt.status != "done" && rt.status != "failed" else {
                throw SidecarError.httpError(status: 400,
                                             detail: "圆桌已结束（\(rt.status)），无需停止")
            }
            NativeRoundtable.requestCancel(rtId)
        } catch let e as SidecarError { throw e }
        catch { throw mapError(error) }
    }

    /// POST .../export 等价（L1993-1999）：NativeRoundtableError → 404 原文案。
    public func exportRoundtable(projectId: String, rtId: String) async throws -> RoundtableExportResult {
        do {
            let r = try kernel.roundtableEngine.exportRoundtableMd(projectId: projectId, rtId: rtId)
            return RoundtableExportResult(path: r.path, name: r.name)
        } catch let e as NativeRoundtableError {
            throw SidecarError.httpError(status: 404, detail: e.message)
        } catch { throw mapError(error) }
    }

    /// DELETE /api/roundtables/{rtid} 等价（L1970-1991）：404 → running 400 原文案 →
    /// 删行 → 附件文件尽力清理。
    public func deleteRoundtable(projectId: String, rtId: String) async throws {
        do {
            guard let rt = try kernel.database.getRoundtable(projectId: projectId, rtId: rtId) else {
                throw SidecarError.httpError(status: 404, detail: "圆桌不存在")
            }
            guard rt.status != "running" else {
                throw SidecarError.httpError(status: 400, detail: "讨论进行中，不能删除")
            }
            _ = try kernel.database.deleteRoundtable(projectId: projectId, rtId: rtId)
            for att in rt.attachments {
                guard let p = att["saved_path"]?.string, !p.isEmpty else { continue }
                try? FileManager.default.removeItem(atPath: p)
            }
        } catch let e as SidecarError { throw e }
        catch { throw mapError(error) }
    }
}

// MARK: - WorkflowPanelClient（P2-W2 全量原生：store.py L1103-1283 + app.py L2226-2365 +
//   workflow/engine.py 全量；fetchInferenceModels/appEventsStream 已由 Inference 扩展实现）

extension NativeSidecarClient: WorkflowPanelClient {

    /// GET /api/workflows 等价：list_workflows（新→旧）。
    public func listWorkflows() async throws -> [WorkflowRecord] {
        do { return try kernel.workflow.listWorkflowRows().map { $0.record } }
        catch { throw mapError(error) }
    }

    /// POST /api/workflows 等价：宽松校验（strict=False）→ 422「；」拼接前 5 条；
    /// name.strip() 空 → 「未命名工作流」。
    @discardableResult
    public func createWorkflow(name: String, description: String, definition: WorkflowDefinition) async throws -> String {
        let defJSON = definition.asJSONValue
        let errors = NativeWorkflowSchema.validateDefinition(defJSON, strict: false)
        guard errors.isEmpty else {
            throw SidecarError.httpError(status: 422, detail: errors.prefix(5).joined(separator: "；"))
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)   // Python str.strip()
        do {
            let wfId = try kernel.workflow.createWorkflow(
                name: trimmed.isEmpty ? "未命名工作流" : trimmed,
                definition: defJSON, description: description)
            // A13（app.py L2240）：workflow/create 带 workflow_id（用户路径）
            NativeEndpointNotify.change(NativeAppEvents.resourceWorkflow,
                                        NativeAppEvents.actionCreate,
                                        extra: ["workflow_id": .string(wfId)])
            return wfId
        } catch { throw mapError(error) }
    }

    /// GET /api/workflows/{id} 等价：nil → 404「工作流不存在」。
    public func getWorkflow(id: String) async throws -> WorkflowRecord {
        do {
            guard let row = try kernel.workflow.getWorkflowRow(id) else {
                throw SidecarError.httpError(status: 404, detail: "工作流不存在")
            }
            return row.record
        } catch let e as SidecarError { throw e }
        catch { throw mapError(error) }
    }

    /// PUT /api/workflows/{id} 等价：404 → 403「内置工作流不可修改」→
    /// definition 存在才宽松校验（422）→ 显式分支部分更新。
    public func updateWorkflow(id: String, update: WorkflowUpdateRequest) async throws {
        do {
            guard let row = try kernel.workflow.getWorkflowRow(id) else {
                throw SidecarError.httpError(status: 404, detail: "工作流不存在")
            }
            if row.builtIn {
                throw SidecarError.httpError(status: 403, detail: "内置工作流不可修改")
            }
            var defJSON: JSONValue? = nil
            if let def = update.definition {
                let v = def.asJSONValue
                let errors = NativeWorkflowSchema.validateDefinition(v, strict: false)
                guard errors.isEmpty else {
                    throw SidecarError.httpError(status: 422,
                                                 detail: errors.prefix(5).joined(separator: "；"))
                }
                defJSON = v
            }
            try kernel.workflow.updateWorkflow(id, name: update.name, definition: defJSON,
                                               description: update.description)
            // A13（app.py L2268）：workflow/update（用户路径）
            NativeEndpointNotify.change(NativeAppEvents.resourceWorkflow,
                                        NativeAppEvents.actionUpdate,
                                        extra: ["workflow_id": .string(id)])
        } catch let e as SidecarError { throw e }
        catch { throw mapError(error) }
    }

    /// DELETE /api/workflows/{id} 等价：404 → 403「内置工作流不可删除」；运行记录保留。
    public func deleteWorkflow(id: String) async throws {
        do {
            guard let row = try kernel.workflow.getWorkflowRow(id) else {
                throw SidecarError.httpError(status: 404, detail: "工作流不存在")
            }
            if row.builtIn {
                throw SidecarError.httpError(status: 403, detail: "内置工作流不可删除")
            }
            try kernel.workflow.deleteWorkflow(id)
            // A13（app.py L2281）：workflow/delete（用户路径）
            NativeEndpointNotify.change(NativeAppEvents.resourceWorkflow,
                                        NativeAppEvents.actionDelete,
                                        extra: ["workflow_id": .string(id)])
        } catch let e as SidecarError { throw e }
        catch { throw mapError(error) }
    }

    /// POST /api/workflows/{id}/run 等价：404 → 严格校验 422「工作流定义有错误：…」→
    /// 建运行记录 → 引擎事件流映射 SSE（rawData 对齐 _sse_format 的 json.dumps 默认分隔）。
    /// 404/422 在流任务内 finish(throwing:)（对齐 HTTP 层在首个字节前返回错误状态）。
    public func runWorkflow(id: String, params: [String: JSONValue]) -> AsyncThrowingStream<SSEEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let row = try self.kernel.workflow.getWorkflowRow(id) else {
                        throw SidecarError.httpError(status: 404, detail: "工作流不存在")
                    }
                    // 引擎消费 json.loads 后的原始 dict（不经类型化往返，props 零损耗）
                    let defJSON = NativeWorkflowStore.parseDefinition(row.definitionText)
                    let errors = NativeWorkflowSchema.validateDefinition(defJSON, strict: true)
                    guard errors.isEmpty else {
                        throw SidecarError.httpError(
                            status: 422,
                            detail: "工作流定义有错误：" + errors.prefix(5).joined(separator: "；"))
                    }
                    let runId = try self.kernel.workflow.createWorkflowRun(
                        workflowId: id, variables: .object(params))
                    // WorkflowRunReq.sandbox_root 面板不传 → 缺省 ~/Desktop（app.py L2295）
                    let sandbox = NSHomeDirectory() + "/Desktop"
                    let connector = NativeWorkflowHTTPConnector(config: self.kernel.config)
                    // P2-W3a：tool 节点点亮——注册表执行器注入（authorizer=nil：
                    // 对齐 Python execute(..., None)，敏感操作按原文案拒绝）
                    let toolExecutor = NativeRegistryToolExecutor(
                        context: .live(config: self.kernel.config,
                                       guard: self.kernel.networkGuard))
                    let engine = NativeWorkflowEngine(
                        runId: runId, definition: defJSON, connector: connector,
                        store: self.kernel.workflow, runtime: self.kernel.workflowRuntime,
                        sandboxRoot: sandbox, params: params,
                        toolExecutor: toolExecutor,
                        globalReadTimeout: { connector.timeoutReading() },
                        vmodelAgentic: self.kernel.vmodelAgenticRunner)
                    let stream = await engine.run()
                    for await ev in stream {
                        continuation.yield(SSEEvent(
                            event: ev.event,
                            data: ev.data.mapValues { $0.anyValue },
                            rawData: NativeDatabase.dumpsUTF8(.object(ev.data))))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            // 消费方取消（面板停止按钮/离开页面）→ 引擎 onTermination 杀生产者任务
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// GET /api/workflow-runs 等价：limit 钳 min(max(limit,1),100)（端点层职责）。
    public func listWorkflowRuns(workflowId: String?, limit: Int) async throws -> [WorkflowRunRecord] {
        do { return try kernel.workflow.listWorkflowRuns(workflowId: workflowId,
                                                         limit: min(max(limit, 1), 100)) }
        catch { throw mapError(error) }
    }

    /// GET /api/workflow-runs/{id} 等价：404「运行记录不存在」；node_events 随详情附。
    public func getWorkflowRun(id: String) async throws -> WorkflowRunDetail {
        do {
            guard let row = try kernel.workflow.getWorkflowRun(id) else {
                throw SidecarError.httpError(status: 404, detail: "运行记录不存在")
            }
            let events = try kernel.workflow.listWorkflowNodeEvents(id)
            return WorkflowRunDetail(
                id: row.id, workflowId: row.workflowId, status: row.status,
                currentNode: row.currentNode, variables: row.variables.object ?? [:],
                result: row.result, error: row.error,
                createdAt: row.createdAt, updatedAt: row.updatedAt, nodeEvents: events)
        } catch let e as SidecarError { throw e }
        catch { throw mapError(error) }
    }

    /// POST /api/workflow-runs/{id}/approve 等价：404 → 409「当前状态 X 不在等待审批」→
    /// 决议唤醒失败 409「审批已失效（运行可能已结束）」→ 恢复 running。
    public func approveWorkflowRun(runId: String, approved: Bool, comment: String) async throws {
        do {
            guard let row = try kernel.workflow.getWorkflowRun(runId) else {
                throw SidecarError.httpError(status: 404, detail: "运行记录不存在")
            }
            guard row.status == "awaiting_approval" else {
                throw SidecarError.httpError(status: 409,
                                             detail: "当前状态 \(row.status) 不在等待审批")
            }
            guard kernel.workflowRuntime.resolveApproval(runId, approved: approved,
                                                         comment: comment) else {
                throw SidecarError.httpError(status: 409, detail: "审批已失效（运行可能已结束）")
            }
            try kernel.workflow.updateWorkflowRun(runId, status: "running")
        } catch let e as SidecarError { throw e }
        catch { throw mapError(error) }
    }

    /// POST /api/workflow-runs/{id}/stop 等价：404；非进行中返回 ok:false（Void 不抛错）；
    /// 取消标志 + 驳回审批解锁（引擎下一节点边界中止并卸载驻留模型）。
    public func stopWorkflowRun(runId: String) async throws {
        do {
            guard let row = try kernel.workflow.getWorkflowRun(runId) else {
                throw SidecarError.httpError(status: 404, detail: "运行记录不存在")
            }
            guard row.status == "running" || row.status == "awaiting_approval" else {
                return   // {"ok": false, "detail": "当前状态 …，无需停止"}——2xx 不抛错
            }
            kernel.workflowRuntime.requestCancel(runId)
            kernel.workflowRuntime.resolveApproval(runId, approved: false, comment: "用户已停止")
        } catch let e as SidecarError { throw e }
        catch { throw mapError(error) }
    }
}
