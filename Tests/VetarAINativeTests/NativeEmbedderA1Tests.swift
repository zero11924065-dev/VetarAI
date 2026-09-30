//
//  NativeEmbedderA1Tests.swift
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

//  覆盖（0.5.1 性能勘察实证驱动：启动 4.2~4.5s CPU 饱和窗 = bge-m3 预装载）：
//    · loadState 三态流转：notLoaded → loaded（真模型首载）；缺模型 → failed
//      记忆化（重试不翻回 loading，不重复装载尝试）
//    · onFirstLoad：首载成功后触发且仅一次（二次编码不再触发）；
//      出锁后回调——钩子内重入编码（重编码旧向量正是反向调 encodeOne 的场景）
//      不死锁
//    · prewarmInBackground 已删除：全仓无引用（编译期背书）
//

import XCTest
@testable import VetarAINative

final class NativeEmbedderA1Tests: XCTestCase {

    /// 仓内模型目录（gitignored 大资产；缺失 → XCTSkip，与 NativeEmbedderTests 同口径）。
    private static func repoModelDir(_ file: StaticString = #filePath) -> URL {
        // #filePath = <repo>/Tests/VetarAINativeTests/NativeEmbedderA1Tests.swift
        URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent()   // VetarAINativeTests/
            .deletingLastPathComponent()   // Tests/
            .deletingLastPathComponent()   // <repo>/
            .appendingPathComponent("models/bge-m3-coreml", isDirectory: true)
    }

    private var tmpRoot: URL!

    override func setUp() async throws {
        tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("p3_a1_embed_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let tmpRoot { try? FileManager.default.removeItem(at: tmpRoot) }
        tmpRoot = nil
        super.tearDown()
    }

    /// 三态流转 + 钩子一次性 + 钩子出锁重入安全（一次装载付一次 2~5s，断言合并同用例）。
    func testLoadStateTransitionsAndOneShotHook() throws {
        let dir = Self.repoModelDir()
        try XCTSkipUnless(NativeEmbedder.dirIsUsable(dir),
                          "CoreML 模型目录不齐件（\(dir.path)），跳过")
        let embedder = NativeEmbedder(dataRoot: tmpRoot, modelDir: dir)
        XCTAssertEqual(embedder.loadState, .notLoaded,
                       "未触发前恒 notLoaded（真懒加载：无启动预热）")

        let exp = expectation(description: "onFirstLoad 首载后触发")
        // assertForOverFulfill 默认 true：钩子若触发第二次 → 测试自动失败（一次性背书）
        embedder.onFirstLoad = {
            // 出锁后回调背书：钩子内重入编码不得死锁/抛错
            // （NativeRuntime 挂的重编码钩子 → reembedForeignModelEntriesIfNeeded
            //   → embedEntry → encodeOneOrNil 正是这条重入路径）
            XCTAssertNotNil(embedder.encodeOneOrNil("钩子内重入编码"))
            exp.fulfill()
        }
        let vec = embedder.encodeOneOrNil("首次真实使用触发装载")
        XCTAssertNotNil(vec, "真模型首载后编码必须成功")
        wait(for: [exp], timeout: 1)
        XCTAssertEqual(embedder.loadState, .loaded)
        // 二次编码不再触发钩子（若触发，overFulfill 在返回前即报失败——钩子是同步回调）
        _ = embedder.encodeOneOrNil("第二次编码")
        XCTAssertEqual(embedder.loadState, .loaded)
    }

    /// 缺模型：failed 记忆化（重试不翻回 loading、不重复装载尝试）；不触发首载钩子。
    func testLoadStateFailedMemoizedWithoutModel() throws {
        let empty = tmpRoot.appendingPathComponent("empty-models", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let embedder = NativeEmbedder(dataRoot: tmpRoot, modelDir: empty)
        XCTAssertEqual(embedder.loadState, .notLoaded)
        XCTAssertFalse(embedder.modelAvailable())

        let noHook = expectation(description: "缺模型不得触发首载钩子")
        noHook.isInverted = true
        embedder.onFirstLoad = { noHook.fulfill() }

        XCTAssertNil(embedder.encodeOneOrNil("触发装载尝试"))
        XCTAssertEqual(embedder.loadState, .failed, "缺模型装载失败 → failed")
        XCTAssertNil(embedder.encodeOneOrNil("重试"))
        XCTAssertEqual(embedder.loadState, .failed,
                       "失败记忆化：重试走 loadFailed 短路，不翻回 loading")
        wait(for: [noHook], timeout: 0.2)
    }
}
