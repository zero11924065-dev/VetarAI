//
//  NativePluginEndpoints.swift
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

//  逐行为移植（⛔ 只读行为规格源：subagent/sidecar/app.py L844-913 +
//  plugin_loader/loader.py 336 行全量；ADR-0046 P-A 方案）：
//    · POST   /api/plugins/install（L844-851）：git clone+manifest（P2-W3a
//      NativeToolInstall.installPlugin 既有通道——守卫/熔断上报/剥代理/120s
//      逐字继承）；成功 A13 plugin/create；ANY 异常 → 400 detail=str(e)
//    · GET    /api/plugins（L853-861）：列表 + enabled/note 两态合并；
//      缺省补齐 entry_point="plugin.py" / hooks=[]
//    · DELETE /api/plugins/{name}（L863-869）：未安装 404「插件 {name} 未安装」；
//      成功 A13 plugin/delete 带 plugin_name
//    · POST   /api/plugins/{name}/toggle（L871-878）：不存在 400
//      「切换失败（插件不存在）」；成功 A13 plugin/update 带 plugin_name
//    · GET    /api/plugins/{name}/note（L883-886）：{name, note}（无备注空串，
//      未安装也 200——Python 不查存在性）
//    · PUT    /api/plugins/{name}/note（L888-893）：空串=清除；A13 update
//    · POST   /api/plugins/{name}/hooks/{hook_name}（L895-905）：禁用 403
//      「插件「{name}」已被禁用（设置 → 插件与技能），无法调用」；模块不可加载/
//      无 hook 404「插件 {name} 没有 hook: {hook_name}」；执行经 python3
//      子进程桥（NativePluginHookBridge）；load_error → 500（Python 进程内
//      语义：exec_module 异常不被捕获）
//    · GET    /api/plugins/{name}/hooks（L907-914）：manifest 读 hooks +
//      entry_point；未安装 404「插件 {name} 未安装」
//
//  A13 口径（L848/868/877/892）：端点成功后才发；install 无 extra，delete/
//  toggle/note 带 plugin_name；GET 端点与 hook 触发不发。
//

import Foundation

public final class NativePluginEndpoints: @unchecked Sendable {

    public let store: NativePluginStore
    /// install 通道（gitRunner/networkGuard/pluginsRoot 经此注入；生产 = 内核
    /// NativeToolContext.live，测试注入假 git runner 绝不触网）。
    public var installContext: NativeToolContext
    /// hook 桥执行器（生产 = NativePluginHookRunner.system；测试可注入假桥）。
    public var hookRunner: NativePluginHookRunner

    public init(store: NativePluginStore, installContext: NativeToolContext,
                hookRunner: NativePluginHookRunner = .system) {
        self.store = store
        self.installContext = installContext
        self.hookRunner = hookRunner
    }

    private func httpError(_ status: Int, _ detail: String) -> SidecarError {
        .httpError(status: status, detail: detail)
    }

    // MARK: - POST /api/plugins/install（L844-851）

    /// 成功 → {"success": true, **info}；ANY 失败 → 400 detail=str(e)。
    @discardableResult
    public func install(repoUrl: String) async throws -> [String: JSONValue] {
        do {
            var result = try await NativeToolInstall.installPlugin(repoUrl, context: installContext)
            // A13（L848）：plugin/create（无 extra）
            NativeEndpointNotify.change(NativeAppEvents.resourcePlugin,
                                        NativeAppEvents.actionCreate)
            result["success"] = .bool(true)
            return result
        } catch let e as NativeGitError {
            throw httpError(400, e.pyDescription)          // ValueError(str) 同形
        } catch let e as NativeToolValueError {
            throw httpError(400, e.message)                // Invalid GitHub URL: …
        } catch let e as NativeNetworkGuardError {
            throw httpError(400, e.message)                // NetworkGuardError(reason)
        } catch let e as NativeCoreError {
            if case .io(let msg) = e { throw httpError(400, msg) }
            throw httpError(400, String(describing: e))
        } catch let e as SidecarError {
            throw e
        } catch {
            throw httpError(400, error.localizedDescription)
        }
    }

    // MARK: - GET /api/plugins（L853-861）

    /// 列表 + 缺省补齐（entry_point/hooks）；manifest 损坏 → 500（微差② detail 带诊断）。
    public func list() throws -> [[String: JSONValue]] {
        var plugins = try store.listInstalled()
        for i in plugins.indices {
            if plugins[i]["entry_point"] == nil { plugins[i]["entry_point"] = .string("plugin.py") }
            if plugins[i]["hooks"] == nil { plugins[i]["hooks"] = .array([]) }
        }
        return plugins
    }

    // MARK: - DELETE /api/plugins/{name}（L863-869）

    @discardableResult
    public func uninstall(name: String) throws -> [String: JSONValue] {
        guard store.uninstall(name) else {
            throw httpError(404, "插件 \(name) 未安装")
        }
        // A13（L868）：plugin/delete 带 plugin_name
        NativeEndpointNotify.change(NativeAppEvents.resourcePlugin,
                                    NativeAppEvents.actionDelete,
                                    extra: ["plugin_name": .string(name)])
        return ["deleted": .bool(true)]
    }

    // MARK: - POST /api/plugins/{name}/toggle（L871-878）

    /// 返回切换后的 enabled。插件不存在 → 400「切换失败（插件不存在）」。
    @discardableResult
    public func toggle(name: String) throws -> Bool {
        let newState: Bool?
        do { newState = try store.toggleEnabled(name) }
        catch let e as NativeCoreError {
            if case .io(let msg) = e { throw httpError(500, msg) }   // manifest 损坏（微差②）
            throw httpError(500, String(describing: e))
        }
        guard let newState else {
            throw httpError(400, "切换失败（插件不存在）")
        }
        // A13（L877）：plugin/update 带 plugin_name
        NativeEndpointNotify.change(NativeAppEvents.resourcePlugin,
                                    NativeAppEvents.actionUpdate,
                                    extra: ["plugin_name": .string(name)])
        return newState
    }

    // MARK: - GET /api/plugins/{name}/note（L883-886）

    public func getNote(name: String) -> [String: JSONValue] {
        ["name": .string(name), "note": .string(store.getNote(name))]
    }

    // MARK: - PUT /api/plugins/{name}/note（L888-893）

    @discardableResult
    public func setNote(name: String, note: String) -> String {
        let final = store.setNote(name, note: note)
        // A13（L892）：plugin/update 带 plugin_name
        NativeEndpointNotify.change(NativeAppEvents.resourcePlugin,
                                    NativeAppEvents.actionUpdate,
                                    extra: ["plugin_name": .string(name)])
        return final
    }

    // MARK: - POST /api/plugins/{name}/hooks/{hook_name}（L895-905）

    /// 禁用 403 / 无 hook 404 / 结果包装 {"plugin","hook","result"|"error"} 逐字。
    /// load_error → 500（Python 进程内语义：_load_plugin_module 异常不被捕获）。
    public func triggerHook(plugin name: String, hook hookName: String,
                            agentContext: [String: JSONValue]) async throws -> [String: JSONValue] {
        // checkpoint-047：逐项开关——被禁用的插件拒绝执行（L898-900）
        guard store.isEnabled(name) else {
            throw httpError(403, "插件「\(name)」已被禁用（设置 → 插件与技能），无法调用")
        }
        // execute_hook → mod is None → 最终 None → 404（L901-904 链）：
        // pdir 缺席 / manifest entry_point 指向的入口文件缺席，全部同文案 404
        let notFound404 = "插件 \(name) 没有 hook: \(hookName)"
        guard store.pluginDirExists(name) else { throw httpError(404, notFound404) }
        let entry = store.entryPoint(name)
        guard store.entryFileExists(name, entryPoint: entry) else {
            throw httpError(404, notFound404)
        }
        let outcome = await hookRunner.run(
            pluginsRoot(name), entry, NativePluginStore.moduleName(name), hookName, agentContext)
        switch outcome {
        case .noHook:
            throw httpError(404, notFound404)
        case .loadError(let e):
            throw httpError(500, e)                        // 微差④：Python 框架 500 通用文案
        case .error(let e):
            return ["plugin": .string(name), "hook": .string(hookName), "error": .string(e)]
        case .result(let r):
            return ["plugin": .string(name), "hook": .string(hookName), "result": r]
        }
    }

    private func pluginsRoot(_ name: String) -> URL {
        store.pluginsRoot.appendingPathComponent(name)
    }

    // MARK: - GET /api/plugins/{name}/hooks（L907-914）

    /// manifest 读 hooks + entry_point；未安装 404「插件 {name} 未安装」。
    public func hooksList(name: String) throws -> [String: JSONValue] {
        let plugins = try store.listInstalled()
        for p in plugins where p["name"]?.string == name {
            return ["name": .string(name),
                    "hooks": p["hooks"] ?? .array([]),
                    "entry_point": p["entry_point"] ?? .string("plugin.py")]
        }
        throw httpError(404, "插件 \(name) 未安装")
    }
}
