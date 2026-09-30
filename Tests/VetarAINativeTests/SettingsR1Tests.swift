//
//  SettingsR1Tests.swift
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

//  覆盖（用户实测反馈驱动：基础设置「原生内核」与数据根区块和关于页重叠）：
//    · saveAll 整包回写保留 data_root 键——基础设置字段移除后不丢键（⭐ 硬约束：
//      设置读写丢键是灾难，SidecarConfigRoundTripTests 同族）
//    · 关于页数据根修改路径：runtime.dataRootPath 写 → UserDefaults
//      sidecar.dataRoot 持久化（AboutRuntimeSection 绑定即此路径）
//    · 默认数据根 = ~/.subagent（P3-W6④ 接管 0.4.x 生产根，0.5.1 不回退）
//

import XCTest
@testable import VetarAINative

@MainActor
final class SettingsR1Tests: XCTestCase {

    /// R1 核心回归：基础设置 data_root 字段移除后，saveAll 整包回写仍带原值。
    /// （UI 无编辑入口 ≠ 键被丢——config.json 内未编辑键随全量 patch 保留。）
    func testSaveAllPreservesDataRootKeyAfterFieldRemoval() async {
        let config = try! JSONDecoder().decode(SidecarConfig.self, from: Data("""
        { "default_model": "qwen3.8", "data_root": "/custom/root", "max_tool_rounds": 200 }
        """.utf8))
        let client = MockSettingsClient(config: config)
        let vm = SettingsViewModel(
            clientProvider: { client },
            sessionIdProvider: { nil },
            logger: TestRuntimeSupport.makeLogger())
        await vm.load()
        vm.draftMaxToolRounds = "250"          // 只改轮次——UI 已无 data_root 字段可碰
        await vm.saveAll()
        XCTAssertEqual(client.putPatches.count, 1)
        XCTAssertEqual(client.putPatches.first?["data_root"]?.string, "/custom/root",
                       "整包回写必须保留未编辑的 data_root 键")
        XCTAssertEqual(client.putPatches.first?["max_tool_rounds"]?.int, 250)
    }

    /// 关于页数据根修改路径：写 runtime.dataRootPath → 持久化 sidecar.dataRoot。
    /// （AboutRuntimeSection 的 TextField 即绑定 runtime.dataRootPath。）
    func testDataRootPathPersistsToUserDefaults() {
        let d = UserDefaults(suiteName: "vetarai-test-r1-\(UUID().uuidString)")!
        // 先注入临时根（TestRuntimeSupport 同纪律：防内核触碰真实 ~/.subagent）
        d.set("/tmp/r1-initial", forKey: NativeRuntime.Keys.dataRoot)
        let runtime = NativeRuntime(defaults: d,
                                    logger: TestRuntimeSupport.makeLogger(),
                                    clientOverride: MockSettingsClient(config: SidecarConfig()))
        XCTAssertEqual(runtime.dataRootPath, "/tmp/r1-initial", "持久化值应被读入")
        runtime.dataRootPath = "/tmp/r1-root"
        XCTAssertEqual(d.string(forKey: NativeRuntime.Keys.dataRoot), "/tmp/r1-root",
                       "关于页改写数据根必须落 UserDefaults（下次启动生效）")
    }

    /// 默认数据根 = ~/.subagent（P3-W6④ 接管 0.4.x 生产根口径，R1 分工不改默认）。
    func testDefaultDataRootIsSubagent() {
        XCTAssertEqual(NativeRuntime.defaultDataRoot, NSHomeDirectory() + "/.subagent")
    }
}
