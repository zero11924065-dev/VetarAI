//
//  NativeOllamaKVCacheTierTests.swift
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

//  不触网、不碰真实 ~/bin / launchctl / UserDefaults；管理器默认使用内存备份。
//

import XCTest
@testable import VetarAINative

final class NativeOllamaKVCacheTierTests: XCTestCase {

    func testTierMappingAndRecommendedDefault() {
        XCTAssertEqual(NativeOllamaKVCacheTier.f16.rawValue, "f16")
        XCTAssertEqual(NativeOllamaKVCacheTier.q8_0.rawValue, "q8_0")
        XCTAssertEqual(NativeOllamaKVCacheTier.q4_0.rawValue, "q4_0")
        XCTAssertEqual(NativeOllamaKVCacheTier.recommended, .q8_0)
        XCTAssertEqual(NativeOllamaKVCacheTier(configuredValue: " \"Q8_0\" "), .q8_0,
                       "读取兼容空白、引号与大小写，写入仍使用规范值")
    }

    func testDetectUnsetRecognizesEveryConfiguredTier() {
        for tier in NativeOllamaKVCacheTier.allCases {
            let env = [
                "OLLAMA_FLASH_ATTENTION": "1",
                "OLLAMA_KV_CACHE_TYPE": tier.rawValue,
            ]
            let mgr = NativeOllamaAccelManager(
                getenv: { env[$0] },
                readScript: { "" }, writeScript: { _ in }, restartOllama: {})
            XCTAssertEqual(mgr.detectUnset(), [], "已设 \(tier.rawValue) 不得判成未优化")
            XCTAssertEqual(mgr.currentKVCacheTier(), tier)
        }
    }

    func testDetectUnsetRecognizesTierConfiguredOnlyInScript() {
        let script = "launchctl setenv OLLAMA_FLASH_ATTENTION 1\n"
            + "launchctl setenv OLLAMA_KV_CACHE_TYPE q4_0\n"
        let mgr = NativeOllamaAccelManager(
            getenv: { _ in nil },
            readScript: { script }, writeScript: { _ in }, restartOllama: {})
        XCTAssertEqual(mgr.detectUnset(), [],
                       "脚本已设 q4_0 但 launchd 尚未刷新时，也不得引导默认 q8_0 覆盖")
        XCTAssertEqual(mgr.currentKVCacheTier(), .q4_0)
    }

    func testDetectUnsetRespectsCustomKVCacheValue() {
        let env = [
            "OLLAMA_FLASH_ATTENTION": "1",
            "OLLAMA_KV_CACHE_TYPE": "custom_user_value",
        ]
        let mgr = NativeOllamaAccelManager(
            getenv: { env[$0] },
            readScript: { "" }, writeScript: { _ in }, restartOllama: {})
        XCTAssertEqual(mgr.detectUnset(), [])
        XCTAssertNil(mgr.currentKVCacheTier(), "自定义值可保留，但不冒充三种已知档位")
    }

    func testApplySelectedQ4TierWritesQ4() {
        var written = ""
        var restarted = false
        let mgr = NativeOllamaAccelManager(
            getenv: { _ in nil },
            readScript: { "launchctl setenv OLLAMA_KEEP_ALIVE 999h\n" },
            writeScript: { written = $0 },
            restartOllama: { restarted = true })
        try! mgr.apply([.kvCacheType], kvCacheTier: .q4_0)
        XCTAssertTrue(written.contains("OLLAMA_KV_CACHE_TYPE q4_0"), written)
        XCTAssertFalse(written.contains("OLLAMA_KV_CACHE_TYPE q8_0"), written)
        XCTAssertTrue(written.contains("OLLAMA_KEEP_ALIVE 999h"), "用户其它变量不动")
        XCTAssertTrue(restarted)
    }

    func testApplySelectedF16TierWritesExplicitF16() {
        var written = ""
        let mgr = NativeOllamaAccelManager(
            getenv: { _ in nil },
            readScript: { "" },
            writeScript: { written = $0 }, restartOllama: {})
        try! mgr.apply([.kvCacheType], kvCacheTier: .f16)
        XCTAssertTrue(written.contains("OLLAMA_KV_CACHE_TYPE f16"), written)
        XCTAssertFalse(written.contains("q8_0"), written)
        XCTAssertFalse(written.contains("q4_0"), written)
    }

    func testDefaultApplyDoesNotOverwriteExistingQ4() {
        var written = ""
        let original = "launchctl setenv OLLAMA_KV_CACHE_TYPE q4_0\n"
        let mgr = NativeOllamaAccelManager(
            getenv: { _ in nil },
            readScript: { original },
            writeScript: { written = $0 }, restartOllama: {})
        try! mgr.apply([.kvCacheType], kvCacheTier: .q8_0)
        XCTAssertTrue(written.contains("OLLAMA_KV_CACHE_TYPE q4_0"), written)
        XCTAssertFalse(written.contains("OLLAMA_KV_CACHE_TYPE q8_0"), written)
        XCTAssertEqual(written.components(separatedBy: "setenv OLLAMA_KV_CACHE_TYPE").count - 1, 1,
                       "默认流程不得追加第二个 KV 配置行")
    }

    func testExplicitTierChangeRestoresPreexistingQ4Backup() {
        let original = "launchctl setenv OLLAMA_KEEP_ALIVE 999h\n"
            + "launchctl setenv OLLAMA_KV_CACHE_TYPE q4_0\n"
        var script = original
        var unsetKeys: Set<String> = []
        var restartCount = 0
        let mgr = NativeOllamaAccelManager(
            getenv: { _ in nil },
            readScript: { script },
            writeScript: { script = $0 },
            restartOllama: { restartCount += 1 },
            unsetenv: { unsetKeys.insert($0) })

        try! mgr.apply([.kvCacheType], kvCacheTier: .q8_0,
                       replaceExistingKVCache: true)
        XCTAssertTrue(script.contains("OLLAMA_KV_CACHE_TYPE q8_0"), script)
        XCTAssertFalse(script.contains("OLLAMA_KV_CACHE_TYPE q4_0"), script)

        try! mgr.restore()
        XCTAssertTrue(script.contains("OLLAMA_KV_CACHE_TYPE q4_0"), "恢复用户优化前原档位")
        XCTAssertFalse(script.contains("OLLAMA_KV_CACHE_TYPE q8_0"), script)
        XCTAssertTrue(script.contains("OLLAMA_KEEP_ALIVE 999h"), "其它用户变量不动")
        XCTAssertFalse(unsetKeys.contains("OLLAMA_KV_CACHE_TYPE"), "原本有值，恢复不应 unset")
        XCTAssertEqual(restartCount, 2)
    }

    func testRepeatedTierChangesRestoreOriginallyUnsetWithoutResidue() {
        let original = "launchctl setenv OLLAMA_KEEP_ALIVE 999h\n"
        var script = original
        var unsetKeys: Set<String> = []
        var restartCount = 0
        let mgr = NativeOllamaAccelManager(
            getenv: { _ in nil },
            readScript: { script },
            writeScript: { script = $0 },
            restartOllama: { restartCount += 1 },
            unsetenv: { unsetKeys.insert($0) })

        try! mgr.apply([.flashAttention, .kvCacheType], kvCacheTier: .q8_0)
        try! mgr.apply([.kvCacheType], kvCacheTier: .q4_0,
                       replaceExistingKVCache: true)
        XCTAssertTrue(script.contains("OLLAMA_KV_CACHE_TYPE q4_0"), script)

        try! mgr.restore()
        XCTAssertFalse(script.contains("OLLAMA_FLASH_ATTENTION"), script)
        XCTAssertFalse(script.contains("OLLAMA_KV_CACHE_TYPE"), script)
        XCTAssertTrue(script.contains("OLLAMA_KEEP_ALIVE 999h"))
        XCTAssertEqual(unsetKeys, ["OLLAMA_FLASH_ATTENTION", "OLLAMA_KV_CACHE_TYPE"],
                       "首次备份为未设置；后续换档不得把 q8_0 误存成恢复目标")
        XCTAssertEqual(restartCount, 3)
    }

    func testRestorePreservesChangesToUnmanagedVariables() {
        var script = "launchctl setenv OLLAMA_KEEP_ALIVE 999h\n"
        let mgr = NativeOllamaAccelManager(
            getenv: { _ in nil },
            readScript: { script },
            writeScript: { script = $0 }, restartOllama: {})
        try! mgr.apply([.flashAttention, .kvCacheType], kvCacheTier: .f16)

        // 模拟用户在优化后通过 1.0.9 环境变量编辑器调整其它变量。
        script += "launchctl setenv OLLAMA_NUM_PARALLEL 8\n"
        try! mgr.restore()
        XCTAssertTrue(script.contains("OLLAMA_KEEP_ALIVE 999h"), script)
        XCTAssertTrue(script.contains("OLLAMA_NUM_PARALLEL 8"), "恢复只还原本模块管理 key")
        XCTAssertFalse(script.contains("OLLAMA_FLASH_ATTENTION"), script)
        XCTAssertFalse(script.contains("OLLAMA_KV_CACHE_TYPE"), script)
    }

    func testFailedFirstWriteDoesNotPoisonNextAttemptBackup() {
        enum WriteError: Error { case failed }
        var script = "launchctl setenv OLLAMA_KV_CACHE_TYPE q4_0\n"
        var shouldFail = true
        let mgr = NativeOllamaAccelManager(
            getenv: { _ in nil },
            readScript: { script },
            writeScript: {
                if shouldFail { throw WriteError.failed }
                script = $0
            },
            restartOllama: {})

        XCTAssertThrowsError(try mgr.apply(
            [.kvCacheType], kvCacheTier: .q8_0, replaceExistingKVCache: true))
        // 首次写入未发生；模拟用户随后把原配置改为 f16，再重试显式换档。
        script = "launchctl setenv OLLAMA_KV_CACHE_TYPE f16\n"
        shouldFail = false
        try! mgr.apply([.kvCacheType], kvCacheTier: .q8_0,
                       replaceExistingKVCache: true)
        try! mgr.restore()
        XCTAssertTrue(script.contains("OLLAMA_KV_CACHE_TYPE f16"), script)
        XCTAssertFalse(script.contains("OLLAMA_KV_CACHE_TYPE q4_0"),
                       "失败首写的旧备份不得覆盖重试前的新原值")
    }
}
