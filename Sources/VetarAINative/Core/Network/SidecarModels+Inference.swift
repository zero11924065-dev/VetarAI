//
//  SidecarModels+Inference.swift
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

//  推理面板 / 模型选项编辑器 / 模型包面板的契约模型。
//  字段逐一对照 subagent/sidecar/app.py 端点与
//  renderer/src/panels/{InferencePanel,ModelOptionsEditor,ModelPacksPanel}.tsx 的实际用法；
//  键名蛇形对齐后端，缺省字段宽容解码（后端附加键不影响）。
//
//  端点核对位置（移植时）：
//    GET  /api/inference/status        app.py:446   → InferenceStatusInfo
//    GET  /api/inference/models        app.py:474   → [InferenceModelEntry]
//    GET  /api/model-packs             app.py:2781  → ModelPackListResponse
//    GET  /api/model-packs/catalog     app.py:2787  → ModelPackCatalogResponse
//    POST /api/model-packs/install     app.py:2822  → {pack_id, catalog_entry}（回传原始目录条目）
//    POST /api/model-packs/cancel      app.py:2856  → {pack_id}
//    DELETE /api/model-packs/{pack_id} app.py:2867
//    POST /api/model-packs/{pack_id}/toggle  app.py:2886 → {enabled}
//    GET  /api/events/stream?since=    app.py:1716  → 全局资源变更 SSE（resource_changed）
//

import Foundation

// MARK: - 推理后端状态（GET /api/inference/status）

/// 后端能力表（connector.capabilities()，唯一事实源）。
public struct InferenceCapabilities: Codable, Equatable, Sendable {
    public var tools: Bool
    public var vision: Bool
    public var pull: Bool
    public var delete: Bool

    public init(tools: Bool = false, vision: Bool = false, pull: Bool = false, delete: Bool = false) {
        self.tools = tools
        self.vision = vision
        self.pull = pull
        self.delete = delete
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tools = try c.decodeIfPresent(Bool.self, forKey: .tools) ?? false
        vision = try c.decodeIfPresent(Bool.self, forKey: .vision) ?? false
        pull = try c.decodeIfPresent(Bool.self, forKey: .pull) ?? false
        delete = try c.decodeIfPresent(Bool.self, forKey: .delete) ?? false
    }

    private enum CodingKeys: String, CodingKey { case tools, vision, pull, delete }
}

/// 当前推理后端状态（在线探测 + 能力表）。
public struct InferenceStatusInfo: Codable, Equatable, Sendable {
    /// "ollama" / "openai_compatible" / "model_package"（旧配置兼容显示）
    public var backend: String
    public var base_url: String
    public var online: Bool
    /// 离线原因明细（连接超时/异常前 200 字）
    public var detail: String
    public var capabilities: InferenceCapabilities

    public init(backend: String = "ollama", base_url: String = "", online: Bool = false,
                detail: String = "", capabilities: InferenceCapabilities = .init()) {
        self.backend = backend
        self.base_url = base_url
        self.online = online
        self.detail = detail
        self.capabilities = capabilities
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        backend = try c.decodeIfPresent(String.self, forKey: .backend) ?? "ollama"
        base_url = try c.decodeIfPresent(String.self, forKey: .base_url) ?? ""
        online = try c.decodeIfPresent(Bool.self, forKey: .online) ?? false
        detail = try c.decodeIfPresent(String.self, forKey: .detail) ?? ""
        capabilities = try c.decodeIfPresent(InferenceCapabilities.self, forKey: .capabilities) ?? .init()
    }

    private enum CodingKeys: String, CodingKey { case backend, base_url, online, detail, capabilities }
}

// MARK: - 统一模型列表（GET /api/inference/models）

/// 统一模型条目（活动后端模型 + 已启用模型包并存，按 model 名自动路由，0.4.30 W2）。
public struct InferenceModelEntry: Codable, Equatable, Identifiable, Sendable {
    public let name: String
    /// 字节数（Ollama 后端带；OpenAI 兼容无）
    public let size: Int64?
    public let context_length: Int?
    /// 0.4.30（W2）来源标记："model_pack" = 模型包（pack_id）；其余/缺省 = 活动后端模型
    public let source: String?

    public var id: String { name }

    public init(name: String, size: Int64? = nil, context_length: Int? = nil, source: String? = nil) {
        self.name = name
        self.size = size
        self.context_length = context_length
        self.source = source
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        if let n = try? c.decodeIfPresent(Int64.self, forKey: .size) {
            size = n
        } else if let d = try? c.decodeIfPresent(Double.self, forKey: .size) {
            size = Int64(d)
        } else {
            size = nil
        }
        context_length = try c.decodeIfPresent(Int.self, forKey: .context_length)
        source = try c.decodeIfPresent(String.self, forKey: .source)
    }

    private enum CodingKeys: String, CodingKey { case name, size, context_length, source }

    /// 模型包来源判定（对齐 TSX `m.source === 'model_pack'`）。
    public var isModelPack: Bool { source == "model_pack" }
}

// MARK: - 模型包（model_packs）

/// 包内文件条目（manifest files[]）。
public struct PackFileInfo: Codable, Equatable, Sendable {
    public let path: String
    public let size_bytes: Int64
    public let sha256: String
    /// 下载源（按序回退）；file:// 本地目录源时为 file URL
    public let sources: [String]?

    public init(path: String, size_bytes: Int64, sha256: String, sources: [String]? = nil) {
        self.path = path
        self.size_bytes = size_bytes
        self.sha256 = sha256
        self.sources = sources
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decodeIfPresent(String.self, forKey: .path) ?? ""
        if let n = try? c.decodeIfPresent(Int64.self, forKey: .size_bytes) {
            size_bytes = n
        } else if let d = try? c.decodeIfPresent(Double.self, forKey: .size_bytes) {
            size_bytes = Int64(d)
        } else {
            size_bytes = 0
        }
        sha256 = try c.decodeIfPresent(String.self, forKey: .sha256) ?? ""
        sources = try c.decodeIfPresent([String].self, forKey: .sources)
    }

    private enum CodingKeys: String, CodingKey { case path, size_bytes, sha256, sources }
}

/// 目录条目（GET /api/model-packs/catalog packs[]；catalog 端点合并时标注
/// source/installed/enabled/installed_version）。
/// 注意：安装时 catalog_entry 须**原样回传**（可选键 context_length/sample_rate 等
/// 不在本模型内，后端 validate_pack 需要它们原样到达）——回传体由 VM 保存的原始
/// JSON 字典承载，本类型仅供展示。
public struct CatalogPack: Codable, Equatable, Identifiable, Sendable {
    public let pack_id: String
    public let name: String
    /// asr | chat | embedding
    public let task: String
    /// onnx | gguf
    public let format: String
    public let driver: String?
    public let version: String
    public let description: String?
    public let size_bytes: Int64?
    public let min_app_version: String?
    public let homepage: String?
    public let license: String?
    public let files: [PackFileInfo]?
    // catalog 端点合并标注
    public let source: String?
    public let installed: Bool?
    public let enabled: Bool?
    public let installed_version: String?

    public var id: String { pack_id }

    public init(pack_id: String, name: String = "", task: String = "", format: String = "",
                driver: String? = nil, version: String = "", description: String? = nil,
                size_bytes: Int64? = nil, min_app_version: String? = nil,
                homepage: String? = nil, license: String? = nil, files: [PackFileInfo]? = nil,
                source: String? = nil, installed: Bool? = nil, enabled: Bool? = nil,
                installed_version: String? = nil) {
        self.pack_id = pack_id
        self.name = name
        self.task = task
        self.format = format
        self.driver = driver
        self.version = version
        self.description = description
        self.size_bytes = size_bytes
        self.min_app_version = min_app_version
        self.homepage = homepage
        self.license = license
        self.files = files
        self.source = source
        self.installed = installed
        self.enabled = enabled
        self.installed_version = installed_version
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pack_id = try c.decodeIfPresent(String.self, forKey: .pack_id) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        task = try c.decodeIfPresent(String.self, forKey: .task) ?? ""
        format = try c.decodeIfPresent(String.self, forKey: .format) ?? ""
        driver = try c.decodeIfPresent(String.self, forKey: .driver)
        version = try c.decodeIfPresent(String.self, forKey: .version) ?? ""
        description = try c.decodeIfPresent(String.self, forKey: .description)
        if let n = try? c.decodeIfPresent(Int64.self, forKey: .size_bytes) {
            size_bytes = n
        } else if let d = try? c.decodeIfPresent(Double.self, forKey: .size_bytes) {
            size_bytes = Int64(d)
        } else {
            size_bytes = nil
        }
        min_app_version = try c.decodeIfPresent(String.self, forKey: .min_app_version)
        homepage = try c.decodeIfPresent(String.self, forKey: .homepage)
        license = try c.decodeIfPresent(String.self, forKey: .license)
        files = try c.decodeIfPresent([PackFileInfo].self, forKey: .files)
        source = try c.decodeIfPresent(String.self, forKey: .source)
        installed = try c.decodeIfPresent(Bool.self, forKey: .installed)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled)
        installed_version = try c.decodeIfPresent(String.self, forKey: .installed_version)
    }

    private enum CodingKeys: String, CodingKey {
        case pack_id, name, task, format, driver, version, description, size_bytes
        case min_app_version, homepage, license, files, source, installed, enabled, installed_version
    }
}

/// 已安装模型包（GET /api/model-packs packs[]；注册表 + 磁盘探测合并）。
public struct InstalledPack: Codable, Equatable, Identifiable, Sendable {
    public let pack_id: String
    public let name: String
    public let description: String?
    public let version: String
    public let task: String
    public let format: String
    public let driver: String?
    /// installed | disabled
    public let status: String
    public let enabled: Bool
    public let installed_at: String?
    public let files: [PackFileInfo]?
    /// SHA256 校验是否全通过
    public let sha256_ok: Bool
    public let size_bytes: Int64
    /// 磁盘缺失文件（相对路径）
    public let missing_files: [String]
    /// 有未完成下载残留（.partial，可断点续传）
    public let has_partial: Bool
    public let dir: String?
    /// chat 包上下文上限（store.py list_installed L221/L231 可选键；未声明 → 0/nil。
    /// P3-W2a：models 并集 MP 部分 HTTP 回源时透传，mp_connector.list_models L102-103 同口径）。
    public let context_length: Int?

    public var id: String { pack_id }

    public init(pack_id: String, name: String = "", description: String? = nil, version: String = "",
                task: String = "", format: String = "", driver: String? = nil,
                status: String = "installed", enabled: Bool = true, installed_at: String? = nil,
                files: [PackFileInfo]? = nil, sha256_ok: Bool = true, size_bytes: Int64 = 0,
                missing_files: [String] = [], has_partial: Bool = false, dir: String? = nil,
                context_length: Int? = nil) {
        self.pack_id = pack_id
        self.name = name
        self.description = description
        self.version = version
        self.task = task
        self.format = format
        self.driver = driver
        self.status = status
        self.enabled = enabled
        self.installed_at = installed_at
        self.files = files
        self.sha256_ok = sha256_ok
        self.size_bytes = size_bytes
        self.missing_files = missing_files
        self.has_partial = has_partial
        self.dir = dir
        self.context_length = context_length
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pack_id = try c.decodeIfPresent(String.self, forKey: .pack_id) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        description = try c.decodeIfPresent(String.self, forKey: .description)
        version = try c.decodeIfPresent(String.self, forKey: .version) ?? ""
        task = try c.decodeIfPresent(String.self, forKey: .task) ?? ""
        format = try c.decodeIfPresent(String.self, forKey: .format) ?? ""
        driver = try c.decodeIfPresent(String.self, forKey: .driver)
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? "installed"
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        installed_at = try c.decodeIfPresent(String.self, forKey: .installed_at)
        files = try c.decodeIfPresent([PackFileInfo].self, forKey: .files)
        sha256_ok = try c.decodeIfPresent(Bool.self, forKey: .sha256_ok) ?? true
        if let n = try? c.decodeIfPresent(Int64.self, forKey: .size_bytes) {
            size_bytes = n
        } else if let d = try? c.decodeIfPresent(Double.self, forKey: .size_bytes) {
            size_bytes = Int64(d)
        } else {
            size_bytes = 0
        }
        missing_files = try c.decodeIfPresent([String].self, forKey: .missing_files) ?? []
        has_partial = try c.decodeIfPresent(Bool.self, forKey: .has_partial) ?? false
        dir = try c.decodeIfPresent(String.self, forKey: .dir)
        if let n = try? c.decodeIfPresent(Int.self, forKey: .context_length) {
            context_length = n
        } else if let d = try? c.decodeIfPresent(Double.self, forKey: .context_length) {
            context_length = Int(d)
        } else {
            context_length = nil
        }
    }

    private enum CodingKeys: String, CodingKey {
        case pack_id, name, description, version, task, format, driver, status, enabled
        case installed_at, files, sha256_ok, size_bytes, missing_files, has_partial, dir
        case context_length
    }

    /// 缺文件或校验未通过 → 警示标记（对齐 TSX corrupted 判定）。
    public var corrupted: Bool { !sha256_ok || !missing_files.isEmpty }
}

/// 目录源拉取失败明细（单源失败不拖死整列）。
public struct ModelPackSourceError: Codable, Equatable, Sendable {
    public let source: String
    public let error: String

    public init(source: String, error: String) {
        self.source = source
        self.error = error
    }
}

/// GET /api/model-packs 响应。
public struct ModelPackListResponse: Codable, Equatable, Sendable {
    public let packs: [InstalledPack]

    public init(packs: [InstalledPack]) { self.packs = packs }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        packs = try c.decodeIfPresent([InstalledPack].self, forKey: .packs) ?? []
    }

    private enum CodingKeys: String, CodingKey { case packs }
}

/// GET /api/model-packs/catalog 响应（packs 合并 + 源错误明细）。
public struct ModelPackCatalogResponse: Codable, Equatable, Sendable {
    public let packs: [CatalogPack]
    /// 拉取成功的源计数（展示用，缺省 0）
    public let sources: Int
    public let source_errors: [ModelPackSourceError]

    public init(packs: [CatalogPack], sources: Int = 0, source_errors: [ModelPackSourceError] = []) {
        self.packs = packs
        self.sources = sources
        self.source_errors = source_errors
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        packs = try c.decodeIfPresent([CatalogPack].self, forKey: .packs) ?? []
        sources = try c.decodeIfPresent(Int.self, forKey: .sources) ?? 0
        source_errors = try c.decodeIfPresent([ModelPackSourceError].self, forKey: .source_errors) ?? []
    }

    private enum CodingKeys: String, CodingKey { case packs, sources, source_errors }
}

// MARK: - ASR（P3-W3b：/api/asr/*；字段名与 Python 端点逐字一致）
//
//  端点核对位置（移植时）：
//    GET  /api/asr/status      app.py:2917  → AsrStatusInfo（三态 ready/disabled/none，永不 5xx）
//    POST /api/asr/transcribe  app.py:2944  → AsrTranscribeOutcome（400 校验链七步 / 409 / 422）

/// `/api/asr/status` 响应。
public struct AsrStatusInfo: Codable, Equatable, Sendable {
    public var available: Bool
    /// ready | disabled | none
    public var state: String
    public var pack_id: String?
    public var message: String?

    public init(available: Bool, state: String, pack_id: String? = nil, message: String? = nil) {
        self.available = available
        self.state = state
        self.pack_id = pack_id
        self.message = message
    }
}

/// `/api/asr/transcribe` 成功响应（C7：saved_path/save_error 互斥出现）。
public struct AsrTranscribeOutcome: Codable, Equatable, Sendable {
    public var text: String
    public var duration_s: Double
    public var model_pack_id: String
    public var saved_path: String?
    public var save_error: String?

    public init(text: String, duration_s: Double, model_pack_id: String,
                saved_path: String? = nil, save_error: String? = nil) {
        self.text = text
        self.duration_s = duration_s
        self.model_pack_id = model_pack_id
        self.saved_path = saved_path
        self.save_error = save_error
    }
}
