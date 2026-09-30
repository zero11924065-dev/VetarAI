//
//  NativePluginStoreTests.swift
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

//  逐条对照 subagent/sidecar/plugin_loader/loader.py（⛔ 只读行为规格源）：
//    · 启用状态：plugins_state.json 默认启用 / 翻转持久化（重开实例读回）/
//      损坏文件静默空表 / toggle 不存在 → nil
//    · 备注：plugins_notes.json set/strip/空串=清除 / 重开实例读回
//    · 列表：sorted 仅目录 / 无 manifest → {name,path} / 有 manifest → 字段+path /
//      enabled·note 两态合并 / manifest 损坏 → 抛（Python 500 口径）
//    · 卸载：rmtree + state/notes 条目清理；**写失败静默 pass**（L263-274 逐字）
//    · hook 模块解析：entry_point manifest 读 / 缺省 plugin.py / 损坏回落 plugin.py
//
//  隔离纪律：全部临时目录（FileManager.temporaryDirectory），绝不碰
//  ~/.subagent/plugins/。
//

import XCTest
@testable import VetarAINative

final class NativePluginStoreTests: XCTestCase {

    private var tmp: URL!
    private var pluginsRoot: URL!
    private var store: NativePluginStore!

    override func setUp() {
        super.setUp()
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("w5plg_\(UUID().uuidString)")
        pluginsRoot = tmp.appendingPathComponent("plugins")
        store = NativePluginStore(pluginsRoot: pluginsRoot)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmp)
        super.tearDown()
    }

    // MARK: - 辅助

    /// 造插件目录（可选 manifest 文本 / plugin.py 内容）。
    @discardableResult
    private func makePlugin(_ name: String, manifest: String? = nil,
                            pluginPy: String? = "def on_message(ctx):\n    return 'hi'\n") -> URL {
        let dir = pluginsRoot.appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let manifest {
            try? manifest.write(to: dir.appendingPathComponent("manifest.json"),
                                atomically: false, encoding: .utf8)
        }
        if let pluginPy {
            try? pluginPy.write(to: dir.appendingPathComponent("plugin.py"),
                                atomically: false, encoding: .utf8)
        }
        return dir
    }

    private func stateOnDisk() throws -> [String: Bool] {
        let data = try Data(contentsOf: pluginsRoot.appendingPathComponent("plugins_state.json"))
        guard case .object(let obj)? = NativeJSONWriter.loads(data) else { return [:] }
        return obj.mapValues { $0.bool ?? false }
    }

    private func notesOnDisk() throws -> [String: String] {
        let data = try Data(contentsOf: pluginsRoot.appendingPathComponent("plugins_notes.json"))
        guard case .object(let obj)? = NativeJSONWriter.loads(data) else { return [:] }
        return obj.mapValues { $0.string ?? "" }
    }

    // MARK: - 启用状态（L56-85）

    /// 默认启用；state 文件不存在/损坏都按启用。
    func testIsEnabledDefaultsTrue() {
        XCTAssertTrue(store.isEnabled("ghost"))
        try? "not json{{".write(to: pluginsRoot.appendingPathComponent("plugins_state.json"),
                                atomically: false, encoding: .utf8)
        XCTAssertTrue(store.isEnabled("ghost"))
    }

    /// toggle：翻转默认 true→false→true；持久化到磁盘；重开实例读回。
    func testTogglePersistsAndReopens() throws {
        makePlugin("alpha")
        XCTAssertEqual(try store.toggleEnabled("alpha"), false)
        XCTAssertFalse(store.isEnabled("alpha"))
        XCTAssertEqual(try stateOnDisk(), ["alpha": false])
        // 重开实例（进程重启语义）
        let store2 = NativePluginStore(pluginsRoot: pluginsRoot)
        XCTAssertFalse(store2.isEnabled("alpha"))
        XCTAssertEqual(try store2.toggleEnabled("alpha"), true)
        XCTAssertEqual(try stateOnDisk(), ["alpha": true])
    }

    /// toggle 不存在插件 → nil（端点 400「切换失败（插件不存在）」）。
    func testToggleMissingReturnsNil() throws {
        XCTAssertNil(try store.toggleEnabled("ghost"))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: pluginsRoot.appendingPathComponent("plugins_state.json").path))
    }

    /// toggle 的 installed 名单走 manifest 的 name 键（L79：p["name"]）。
    func testToggleUsesManifestName() throws {
        makePlugin("dir-name", manifest: #"{"name": "manifest-name"}"#)
        XCTAssertNil(try store.toggleEnabled("dir-name"))            // 目录名不在名单
        XCTAssertEqual(try store.toggleEnabled("manifest-name"), false)
    }

    // MARK: - 备注（L87-122）

    /// set_note：strip 后落库；空串=清除；重开实例读回。
    func testNoteSetStripClear() throws {
        XCTAssertEqual(store.getNote("alpha"), "")
        XCTAssertEqual(store.setNote("alpha", note: "  给消息加时间戳  "), "给消息加时间戳")
        XCTAssertEqual(try notesOnDisk(), ["alpha": "给消息加时间戳"])
        let store2 = NativePluginStore(pluginsRoot: pluginsRoot)
        XCTAssertEqual(store2.getNote("alpha"), "给消息加时间戳")
        // 空串=清除（条目 pop，不是空串留存）
        XCTAssertEqual(store2.setNote("alpha", note: "   "), "")
        XCTAssertEqual(try notesOnDisk(), [:])
        XCTAssertEqual(store2.getNote("alpha"), "")
    }

    /// 备注文件损坏 → 空表静默。
    func testNotesCorruptSilentEmpty() {
        try? "{{bad".write(to: pluginsRoot.appendingPathComponent("plugins_notes.json"),
                           atomically: false, encoding: .utf8)
        XCTAssertEqual(store.getNote("alpha"), "")
    }

    // MARK: - 列表（L231-251）

    /// 无 manifest → {name, path} + enabled/note 合并；缺省目录也列出。
    func testListWithoutManifest() throws {
        makePlugin("raw-dir", manifest: nil)
        let list = try store.listInstalled()
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list[0]["name"]?.string, "raw-dir")
        XCTAssertEqual(list[0]["path"]?.string, pluginsRoot.appendingPathComponent("raw-dir").path)
        XCTAssertEqual(list[0]["enabled"]?.bool, true)      // 默认启用
        XCTAssertEqual(list[0]["note"]?.string, "")
        XCTAssertNil(list[0]["entry_point"])                // 补齐在端点层（app.py L856-860）
        XCTAssertNil(list[0]["hooks"])
    }

    /// 有 manifest → manifest 字段 + path 注入 + 两态合并；sorted 排序；文件跳过。
    func testListWithManifestMergesStates() throws {
        makePlugin("beta", manifest: #"{"name": "beta", "version": "1.2.3", "hooks": ["on_message"]}"#)
        makePlugin("alpha", manifest: #"{"name": "alpha"}"#)
        try? "x".write(to: pluginsRoot.appendingPathComponent("loose-file.txt"),
                       atomically: false, encoding: .utf8)   // 非目录跳过
        _ = try store.toggleEnabled("beta")
        _ = store.setNote("beta", note: "备注B")
        let list = try store.listInstalled()
        XCTAssertEqual(list.map { $0["name"]?.string }, ["alpha", "beta"])   // sorted
        let beta = list[1]
        XCTAssertEqual(beta["version"]?.string, "1.2.3")
        XCTAssertEqual(beta["hooks"]?.stringArray, ["on_message"])
        XCTAssertEqual(beta["enabled"]?.bool, false)
        XCTAssertEqual(beta["note"]?.string, "备注B")
        XCTAssertEqual(list[0]["enabled"]?.bool, true)
        XCTAssertEqual(list[0]["note"]?.string, "")
    }

    /// manifest 损坏 → 抛（Python json.loads 上抛 → 端点 500 同口径，微差②）。
    func testListCorruptManifestThrows() {
        makePlugin("broken", manifest: "{{not json")
        XCTAssertThrowsError(try store.listInstalled()) { err in
            guard case .io(let msg) = err as? NativeCoreError else {
                return XCTFail("应为 NativeCoreError.io，实得 \(err)")
            }
            XCTAssertTrue(msg.contains("broken"), msg)
        }
    }

    // MARK: - 卸载（L253-275）

    /// 卸载：rmtree + state/notes 条目清理（其他插件条目保留）；未安装 → false。
    func testUninstallCleansStateAndNotes() throws {
        makePlugin("gone")
        makePlugin("stay")
        _ = try store.toggleEnabled("gone")
        _ = try store.toggleEnabled("stay")
        _ = store.setNote("gone", note: "bye")
        _ = store.setNote("stay", note: "hi")
        XCTAssertTrue(store.uninstall("gone"))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: pluginsRoot.appendingPathComponent("gone").path))
        XCTAssertEqual(try stateOnDisk(), ["stay": false])
        XCTAssertEqual(try notesOnDisk(), ["stay": "hi"])
        XCTAssertFalse(store.uninstall("gone"))          // 幂等：已删 → false
    }

    /// 无 state/notes 条目的卸载：不创建两个 JSON（Python if plugin_name in state 才写）。
    func testUninstallWithoutEntriesCreatesNoJSON() throws {
        makePlugin("plain")
        XCTAssertTrue(store.uninstall("plain"))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: pluginsRoot.appendingPathComponent("plugins_state.json").path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: pluginsRoot.appendingPathComponent("plugins_notes.json").path))
    }

    /// 清理写失败静默 pass（L263-274 逐字）：.tmp 路径被目录占位 → rename/write
    /// 必败 → 卸载仍返回 true，目录已删。
    func testUninstallCleanupWriteFailureSilent() throws {
        makePlugin("victim")
        _ = try store.toggleEnabled("victim")
        // 堵死 plugins_state.json.tmp（目录占位 → write_text 失败）
        try FileManager.default.createDirectory(
            at: pluginsRoot.appendingPathComponent("plugins_state.json.tmp"),
            withIntermediateDirectories: true)
        XCTAssertTrue(store.uninstall("victim"))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: pluginsRoot.appendingPathComponent("victim").path))
    }

    // MARK: - hook 模块解析（L279-305 前半段）

    /// entry_point：manifest 读；缺席/损坏/缺键 → plugin.py；模块名 - 换 _。
    func testEntryPointResolution() {
        makePlugin("with-mf", manifest: #"{"entry_point": "main.py"}"#)
        XCTAssertEqual(store.entryPoint("with-mf"), "main.py")
        makePlugin("no-mf", manifest: nil)
        XCTAssertEqual(store.entryPoint("no-mf"), "plugin.py")
        makePlugin("bad-mf", manifest: "{{bad")
        XCTAssertEqual(store.entryPoint("bad-mf"), "plugin.py")
        XCTAssertEqual(NativePluginStore.moduleName("my-plugin"), "subagent_plugin_my_plugin")
        XCTAssertTrue(store.pluginDirExists("with-mf"))
        XCTAssertFalse(store.pluginDirExists("ghost"))
        XCTAssertTrue(store.entryFileExists("with-mf", entryPoint: "plugin.py"))
        XCTAssertFalse(store.entryFileExists("with-mf", entryPoint: "main.py"))
    }
}
