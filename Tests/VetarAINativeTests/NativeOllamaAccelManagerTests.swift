//
//  NativeOllamaAccelManagerTests.swift
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

//  覆盖（不触网、不碰真实 ~/bin 脚本、不真 restart）：
//    · detectUnset：getenv 桩 → 未设置项（已设置项不在结果）
//    · appendEnvLines：追加 + 幂等（已存在不重复）
//    · removeEnvLines：按 key 移除（恢复用）
//    · apply/restore：readScript/writeScript/restartOllama 三缝录证
//

import XCTest
@testable import VetarAINative

final class NativeOllamaAccelManagerTests: XCTestCase {

    func testDetectUnset() {
        var env: [String: String] = [
            "OLLAMA_FLASH_ATTENTION": "1",
            // KV_CACHE_TYPE 未设置
        ]
        let mgr = NativeOllamaAccelManager(
            getenv: { env[$0] },
            readScript: { "" }, writeScript: { _ in }, restartOllama: {})
        XCTAssertEqual(mgr.detectUnset(), [.kvCacheType],
                       "flash 已设置 → 只返回未设置的 kvCacheType")
    }

    func testDetectUnsetAll() {
        let mgr = NativeOllamaAccelManager(
            getenv: { _ in nil },
            readScript: { "" }, writeScript: { _ in }, restartOllama: {})
        XCTAssertEqual(mgr.detectUnset(), NativeOllamaOptimization.allCases)
    }

    func testAppendEnvLinesAndIdempotent() {
        let base = "launchctl setenv OLLAMA_KEEP_ALIVE 999h\n"
        let once = NativeOllamaAccelManager.appendEnvLines(
            to: base, additions: [("OLLAMA_FLASH_ATTENTION", "1")])
        XCTAssertTrue(once.contains("setenv OLLAMA_FLASH_ATTENTION 1"), once)
        XCTAssertTrue(once.contains("OLLAMA_KEEP_ALIVE"), "保留原有行")
        // 幂等：再追加一次不重复
        let twice = NativeOllamaAccelManager.appendEnvLines(
            to: once, additions: [("OLLAMA_FLASH_ATTENTION", "1")])
        XCTAssertEqual(twice.components(separatedBy: "setenv OLLAMA_FLASH_ATTENTION").count - 1, 1,
                       "重复追加不产生第二行")
    }

    func testRemoveEnvLines() {
        let base = "launchctl setenv OLLAMA_KEEP_ALIVE 999h\n"
            + "launchctl setenv OLLAMA_FLASH_ATTENTION 1\n"
            + "launchctl setenv OLLAMA_KV_CACHE_TYPE q8_0\n"
        let removed = NativeOllamaAccelManager.removeEnvLines(
            from: base, keys: ["OLLAMA_FLASH_ATTENTION", "OLLAMA_KV_CACHE_TYPE"])
        XCTAssertFalse(removed.contains("FLASH_ATTENTION"), removed)
        XCTAssertFalse(removed.contains("KV_CACHE_TYPE"), removed)
        XCTAssertTrue(removed.contains("KEEP_ALIVE"), "只移除本模块 key，用户自设项不动")
    }

    func testApplyWritesAndRestarts() {
        var written = ""
        var restarted = false
        let mgr = NativeOllamaAccelManager(
            getenv: { _ in nil },
            readScript: { "launchctl setenv OLLAMA_KEEP_ALIVE 999h\n" },
            writeScript: { written = $0 },
            restartOllama: { restarted = true })
        try! mgr.apply([.flashAttention, .kvCacheType])
        XCTAssertTrue(written.contains("OLLAMA_FLASH_ATTENTION 1"), written)
        XCTAssertTrue(written.contains("OLLAMA_KV_CACHE_TYPE q8_0"), written)
        XCTAssertTrue(written.contains("OLLAMA_KEEP_ALIVE 999h"), "保留用户自设")
        XCTAssertTrue(restarted, "应用后重启 Ollama")
    }

    func testRestoreRemovesAndRestarts() {
        var written = ""
        var restarted = false
        let base = "launchctl setenv OLLAMA_KEEP_ALIVE 999h\n"
            + "launchctl setenv OLLAMA_FLASH_ATTENTION 1\n"
            + "launchctl setenv OLLAMA_KV_CACHE_TYPE q8_0\n"
        let mgr = NativeOllamaAccelManager(
            getenv: { _ in nil },
            readScript: { base },
            writeScript: { written = $0 },
            restartOllama: { restarted = true })
        try! mgr.restore()
        XCTAssertFalse(written.contains("FLASH_ATTENTION"), written)
        XCTAssertFalse(written.contains("KV_CACHE_TYPE"), written)
        XCTAssertTrue(written.contains("KEEP_ALIVE"), "恢复只撤本模块项")
        XCTAssertTrue(restarted)
    }

    // MARK: - 读取 / 逐项编辑（业主 2026-10-26）

    func testParseOllamaEnvLinesFiltersNonOllama() {
        let script = """
        #!/bin/bash
        # 注释
        launchctl setenv OLLAMA_HOST 0.0.0.0:11434
        launchctl setenv OLLAMA_KEEP_ALIVE 999h
        launchctl setenv OLLAMA_NUM_PARALLEL 4
        launchctl setenv OLLAMA_CONTEXT_LENGTH 131072

        # 代理
        NP="127.0.0.1,localhost"
        launchctl setenv NO_PROXY "$NP"
        launchctl setenv no_proxy "$NP"
        """
        let parsed = NativeOllamaAccelManager.parseOllamaEnvLines(from: script)
        XCTAssertEqual(parsed.map(\.key),
                       ["OLLAMA_HOST", "OLLAMA_KEEP_ALIVE", "OLLAMA_NUM_PARALLEL", "OLLAMA_CONTEXT_LENGTH"],
                       "只解析 OLLAMA_ 前缀；NO_PROXY/no_proxy/变量赋值/注释全部过滤")
        XCTAssertEqual(parsed.first?.value, "0.0.0.0:11434")
    }

    func testReplaceOllamaEnvLinesPreservesNonOllama() {
        let script = """
        #!/bin/bash
        launchctl setenv OLLAMA_HOST 0.0.0.0:11434
        launchctl setenv OLLAMA_KEEP_ALIVE 999h
        NP="127.0.0.1"
        launchctl setenv NO_PROXY "$NP"
        """
        let updated = NativeOllamaAccelManager.replaceOllamaEnvLines(
            in: script, with: [("OLLAMA_HOST", "127.0.0.1:11434"),
                               ("OLLAMA_NUM_PARALLEL", "8")])
        XCTAssertTrue(updated.contains("#!/bin/bash"), "保留 shebang")
        XCTAssertTrue(updated.contains("NP=\"127.0.0.1\""), "保留变量赋值")
        XCTAssertTrue(updated.contains("NO_PROXY"), "保留代理行")
        XCTAssertFalse(updated.contains("OLLAMA_KEEP_ALIVE 999h"), "旧 OLLAMA 行被替换")
        XCTAssertTrue(updated.contains("OLLAMA_HOST 127.0.0.1:11434"), "新值")
        XCTAssertTrue(updated.contains("OLLAMA_NUM_PARALLEL 8"), "新增变量")
    }

    func testListEnvVarsMapsEffective() {
        let mgr = NativeOllamaAccelManager(
            getenv: { $0 == "OLLAMA_NUM_PARALLEL" ? "4" : nil },
            readScript: {
                "launchctl setenv OLLAMA_KEEP_ALIVE 999h\n"
                + "launchctl setenv OLLAMA_NUM_PARALLEL 4\n" },
            writeScript: { _ in }, restartOllama: {})
        let vars = try! mgr.listEnvVars()
        XCTAssertEqual(vars.count, 2)
        let np = vars.first { $0.key == "OLLAMA_NUM_PARALLEL" }
        XCTAssertEqual(np?.effective, "4")
        XCTAssertTrue(np?.isSynced == true, "生效值与脚本值一致")
        let ka = vars.first { $0.key == "OLLAMA_KEEP_ALIVE" }
        XCTAssertNil(ka?.effective, "未设置 → 生效值 nil")
        XCTAssertFalse(ka?.isSynced ?? true, "脚本有值但未生效 → 不同步")
    }

    func testSaveEnvVarsWritesAndRestarts() {
        var written = ""
        var restarted = false
        let base = "#!/bin/bash\nlaunchctl setenv OLLAMA_KEEP_ALIVE 999h\nlaunchctl setenv NO_PROXY \"$NP\"\n"
        let mgr = NativeOllamaAccelManager(
            getenv: { _ in nil },
            readScript: { base },
            writeScript: { written = $0 },
            restartOllama: { restarted = true })
        try! mgr.saveEnvVars([
            NativeOllamaEnvVar(key: "OLLAMA_KEEP_ALIVE", value: "30m", effective: nil),
            NativeOllamaEnvVar(key: "OLLAMA_FLASH_ATTENTION", value: "1", effective: nil),
        ])
        XCTAssertTrue(written.contains("OLLAMA_KEEP_ALIVE 30m"), written)
        XCTAssertTrue(written.contains("OLLAMA_FLASH_ATTENTION 1"), written)
        XCTAssertTrue(written.contains("NO_PROXY"), "保留代理行")
        XCTAssertFalse(written.contains("OLLAMA_KEEP_ALIVE 999h"), "旧值被替换")
        XCTAssertTrue(restarted)
    }
}
