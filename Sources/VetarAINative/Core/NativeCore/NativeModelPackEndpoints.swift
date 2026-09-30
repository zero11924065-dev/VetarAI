//
//  NativeModelPackEndpoints.swift
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

//  逐行为移植（⛔ 只读行为规格源：subagent/sidecar/app.py L2746-2900）：
//    · GET /api/model-packs（L2781-2784）：注册表+磁盘探测列表
//    · GET /api/model-packs/catalog（L2787-2819）：逐源拉 model_pack_catalog_urls
//      合并——pack_id 跨源去重先出现生效，标注 source/installed/enabled/
//      installed_version，sources=ok 计数，单源失败进 source_errors 不拖死整列
//    · POST install（L2822-2853）：400 链（pack_id 不一致 → 非法 slug →
//      catalog_entry 校验失败前 5 条；连接）→ 409（已安装/下载中）→
//      {accepted}；生命周期事件由下载器发射，端点不重复 notify
//    · POST cancel（L2856-2864）：无进行中任务 404 逐字；成功 notify(update,
//      phase="cancelled"）
//    · DELETE（L2867-2883）：在飞先 cancel → _release_pack_runtime → remove_pack
//      false→404 逐字 → notify(delete)
//    · POST toggle（L2886-2900）：set_enabled nil→404 逐字；禁用时 release
//      runtime；notify(update, enabled=new_state)
//    · _release_pack_runtime（L2759-2778）：chat 面 = stop_server(pack_id)
//      （驱动名字匹配防护）+ ASR 面 = asrDriver.unload(pack_id)（P3-W3b 接通，
//      同样按 pack_id 匹配防误卸）
//
//  偏差（汇报清单同步）：
//    ① install 的 `except RuntimeError → 500` 在 Python 不可达（pack_dir 解析在
//       后台任务内，失败走 download_error 事件）——按实际行为复刻（downloader
//       文件头偏差④同款）。
//    ② events/stream 面板客户端仍 HTTP（偏差⑦，不动）。
//

import Foundation

/// /api/model-packs 六端点装配体（面板经 NativeSidecarClient+Panels 调用；
/// 错误一律 SidecarError.httpError 与 HTTP 层同形——面板 ViewModel 零改动）。
public final class NativeModelPackEndpoints: @unchecked Sendable {

    public let store: NativeModelPackStore
    public let downloader: NativeModelPackDownloader
    public let manager: NativeModelPackDownloadManager
    public let driver: NativeLlamaCppDriver
    /// P3-W3b：ASR 驱动（可空——kernel 装配注入；单测不注入则 ASR 面无释放动作，
    /// 既有行为不变）。卸载/禁用时回收 onnx session（app.py L2774-2778 同构：
    /// asr_driver.unload(pack_id) 自带 pack_id 匹配防护，不误卸在跑的转写）。
    public var asrDriver: NativeAsrDriver?
    /// 0.7.7 W3：MLX 模型包驱动（可空——kernel 装配注入；不注入则 MLX 面无
    /// 释放动作）。卸载/禁用 driver=mlxswift 包时回收进程内驻留引擎
    /// （unload(pack_id) 自带 pack_id 匹配防护，不误卸在跑的对话）。
    public var mlxDriver: NativeMPMLXDriver?
    public var configProvider: @Sendable () -> [String: JSONValue]
    /// _notify_change 缝（默认原生总线；测试捕获）。
    public var notify: @Sendable (String, String, [String: JSONValue]) -> Void = { resource, action, extra in
        NativeEndpointNotify.change(resource, action, extra: extra)
    }
    public var log: @Sendable (String) -> Void = { _ in }

    public init(store: NativeModelPackStore,
                downloader: NativeModelPackDownloader,
                manager: NativeModelPackDownloadManager,
                driver: NativeLlamaCppDriver,
                configProvider: @escaping @Sendable () -> [String: JSONValue]) {
        self.store = store
        self.downloader = downloader
        self.manager = manager
        self.driver = driver
        self.configProvider = configProvider
    }

    private func httpError(_ status: Int, _ detail: String) -> SidecarError {
        .httpError(status: status, detail: detail)
    }

    // MARK: - GET /api/model-packs（L2781-2784）

    public func listPacks() -> ModelPackListResponse {
        ModelPackListResponse(packs: store.listInstalled().map(Self.installedPack))
    }

    static func installedPack(_ p: [String: JSONValue]) -> InstalledPack {
        InstalledPack(
            pack_id: p["pack_id"]?.string ?? "",
            name: p["name"]?.string ?? "",
            description: p["description"]?.string,
            version: p["version"]?.string ?? "",
            task: p["task"]?.string ?? "",
            format: p["format"]?.string ?? "",
            driver: p["driver"]?.string,
            status: p["status"]?.string ?? "installed",
            enabled: p["enabled"]?.bool ?? true,
            installed_at: p["installed_at"]?.string,
            files: p["files"]?.array?.map(packFile),
            sha256_ok: p["sha256_ok"]?.bool ?? true,
            size_bytes: p["size_bytes"].flatMap(PySem.toFloat).map { Int64($0) } ?? 0,
            missing_files: p["missing_files"]?.array?.compactMap { $0.string } ?? [],
            has_partial: p["has_partial"]?.bool ?? false,
            dir: p["dir"]?.string,
            context_length: p["context_length"].flatMap(PySem.toFloat).map { Int($0) })
    }

    static func packFile(_ f: JSONValue) -> PackFileInfo {
        PackFileInfo(
            path: f.object?["path"]?.string ?? "",
            size_bytes: f.object?["size_bytes"].flatMap(PySem.toFloat).map { Int64($0) } ?? 0,
            sha256: f.object?["sha256"]?.string ?? "",
            sources: f.object?["sources"]?.array?.compactMap { $0.string })
    }

    // MARK: - GET /api/model-packs/catalog（L2787-2819）

    public func catalog() async -> (catalog: ModelPackCatalogResponse,
                                    rawEntries: [String: [String: Any]]) {
        let urls = configProvider()["model_pack_catalog_urls"]?.array ?? []
        let installed = store.readRegistry()
        var merged: [[String: JSONValue]] = []
        var seen: Set<String> = []
        var sourceErrors: [ModelPackSourceError] = []
        var okSources = 0
        for u in urls {
            let url = WFText.pyStr(u)
            let (packs, err) = await downloader.fetchCatalog(url)
            if let err {
                sourceErrors.append(ModelPackSourceError(source: url, error: err))
                continue
            }
            okSources += 1
            for p in packs ?? [] {
                let pid = p["pack_id"].map(WFText.pyStr) ?? ""
                if seen.contains(pid) { continue }   // 跨源去重：先出现生效
                seen.insert(pid)
                let entry = installed[pid]
                var m = p
                m["source"] = .string(url)
                m["installed"] = .bool(entry != nil)
                m["enabled"] = .bool(entry?["status"]?.string == "installed")
                m["installed_version"] = .string(entry?["version"].map(WFText.pyStr) ?? "")
                merged.append(m)
            }
        }
        var raw: [String: [String: Any]] = [:]
        let catalogPacks: [CatalogPack] = merged.map { m in
            let pid = m["pack_id"].map(WFText.pyStr) ?? ""
            raw[pid] = m.mapValues { $0.anyValue }   // 原样回传保住可选键（HTTP 同款）
            return CatalogPack(
                pack_id: pid,
                name: m["name"]?.string ?? "",
                task: m["task"]?.string ?? "",
                format: m["format"]?.string ?? "",
                driver: m["driver"]?.string,
                version: m["version"]?.string ?? "",
                description: m["description"]?.string,
                size_bytes: m["size_bytes"].flatMap(PySem.toFloat).map { Int64($0) },
                min_app_version: m["min_app_version"]?.string,
                homepage: m["homepage"]?.string,
                license: m["license"]?.string,
                files: m["files"]?.array?.map(Self.packFile),
                source: m["source"]?.string,
                installed: m["installed"]?.bool,
                enabled: m["enabled"]?.bool,
                installed_version: m["installed_version"]?.string)
        }
        return (ModelPackCatalogResponse(packs: catalogPacks, sources: okSources,
                                         source_errors: sourceErrors), raw)
    }

    // MARK: - POST /api/model-packs/install（L2822-2853）

    /// 立即返回（下载走后台任务，进度经下载器生命周期事件上 SSE）。
    public func install(packId: String, catalogEntry: [String: JSONValue]) throws {
        let pack = catalogEntry
        if packId != (pack["pack_id"].map(WFText.pyStr) ?? "") {
            throw httpError(400, "pack_id 与 catalog_entry.pack_id 不一致")
        }
        guard NativeModelPackManifest.validPackId(.string(packId)) else {
            throw httpError(400, "非法 pack_id（须 slug 小写字母/数字/-/_，1~64 长）: "
                + PySem.reprString(packId))
        }
        let errors = NativeModelPackManifest.validatePack(.object(pack))
        guard errors.isEmpty else {
            throw httpError(400, "catalog_entry 校验失败: " + errors.prefix(5).joined(separator: "；"))
        }
        guard !store.isInstalled(packId) else {
            throw httpError(409, "模型包 \(packId) 已安装；如需重装请先卸载")
        }
        do {
            try manager.start(packId, pack: pack)
        } catch let e as NativePackDownloadError {
            throw httpError(409, e.message)   // 重复启动（进行中）
        }
        // 生命周期事件（download_start/done/error）由下载器发射，这里不重复 notify
    }

    // MARK: - POST /api/model-packs/cancel（L2856-2864）

    public func cancel(packId: String) async throws {
        let ok = await manager.cancel(packId)
        guard ok else {
            throw httpError(404, "模型包 \(packId) 没有进行中的下载任务")
        }
        notify(NativeAppEvents.resourceModelPack, NativeAppEvents.actionUpdate,
               ["pack_id": .string(packId), "phase": .string("cancelled")])
    }

    // MARK: - DELETE /api/model-packs/{pack_id}（L2867-2883）

    public func deletePack(_ packId: String) async throws {
        if manager.isActive(packId) {
            _ = await manager.cancel(packId)   // 有下载进行中先取消（.partial 保留）
        }
        await releasePackRuntime(packId)
        let ok = try store.removePack(packId)
        guard ok else {
            throw httpError(404, "模型包 \(packId) 未安装")
        }
        notify(NativeAppEvents.resourceModelPack, NativeAppEvents.actionDelete,
               ["pack_id": .string(packId)])
    }

    // MARK: - POST /api/model-packs/{pack_id}/toggle（L2886-2900）

    public func toggle(packId: String, enabled: Bool) async throws {
        guard let newState = store.setEnabled(packId, enabled: enabled) else {
            throw httpError(404, "模型包 \(packId) 未安装")
        }
        if !newState {
            await releasePackRuntime(packId)   // 禁用＝立即回收运行时（缺陷修复 A/B 配套）
        }
        notify(NativeAppEvents.resourceModelPack, NativeAppEvents.actionUpdate,
               ["pack_id": .string(packId), "enabled": .bool(newState)])
    }

    // MARK: - _release_pack_runtime（L2759-2778）

    /// chat 面：stop_server(pack_id)（驱动名字匹配防护，不误停正在跑的对话）；
    /// ASR 面：asrDriver.unload(pack_id)（P3-W3b 接通——同样按 pack_id 匹配防误卸）；
    /// MLX 面（0.7.7 W3）：mlxDriver.unload(pack_id)（同名匹配防护，卸进程内
    /// 驻留引擎还统一内存）。
    /// 异常不阻断卸载/禁用主流程（驱动层注册表门禁下次对话兜底回收）。
    private func releasePackRuntime(_ packId: String) async {
        _ = await driver.stopServer(packId)
        _ = asrDriver?.unload(packId)
        _ = await mlxDriver?.unload(packId)
    }
}
