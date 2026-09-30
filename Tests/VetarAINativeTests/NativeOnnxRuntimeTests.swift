//
//  NativeOnnxRuntimeTests.swift
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

//  锚定：
//    · 三态解析链（NativeLlamaCppDriver.resolveServerBinary 先例；P3-W6④
//      翻转）：bundle Resources/onnxruntime > env >
//      {data_root}/drivers/onnxruntime——bundle 最高，数据根兜底；
//      env 非法继续回退；全失 → 中文明细含已查找列表
//    · ABI 镜像尺寸/偏移断言（425 字段 × 8B；关键函数 idx 钉死——布局错一位
//      就是函数指针乱飞，本组断言是免崩保险）
//    · 真 dylib skip-unless 冒烟：VETARAI_ONNXRUNTIME 或本机 venv 实物存在时
//      dlopen + GetApi(29) + CreateEnv/版本号校验（CI/换机缺库不阻塞）
//

import XCTest
@testable import VetarAINative

final class NativeOnnxRuntimeTests: XCTestCase {

    private var tmp: URL!

    override func setUp() {
        super.setUp()
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ort_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmp)
        super.tearDown()
    }

    private func touch(_ rel: String) -> URL {
        let url = tmp.appendingPathComponent(rel)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: Data([0]))
        return url
    }

    // MARK: - 三态解析链（P3-W6④：bundle > env > dataRoot）

    func testResolveBundleFirst() throws {
        // 三候选全在 → bundle 最高优先（包内 dylib 与 ABI 镜像同版本发行）
        let envDylib = touch("custom/libort.dylib")
        _ = touch("drivers/onnxruntime/libonnxruntime.dylib")
        let bundle = tmp.appendingPathComponent("bundle")
        let bundleDylib = bundle.appendingPathComponent("onnxruntime/libonnxruntime.dylib")
        try FileManager.default.createDirectory(
            at: bundleDylib.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: bundleDylib.path, contents: Data([0]))
        let got = try NativeOnnxRuntime.resolveDylib(
            environment: ["VETARAI_ONNXRUNTIME": envDylib.path],
            dataRootProvider: { self.tmp }, bundleResourceURL: bundle)
        XCTAssertEqual(got.path, bundleDylib.path)
    }

    func testResolveEnvWinsWhenBundleAbsent() throws {
        let envDylib = touch("custom/libort.dylib")
        _ = touch("drivers/onnxruntime/libonnxruntime.dylib")
        let got = try NativeOnnxRuntime.resolveDylib(
            environment: ["VETARAI_ONNXRUNTIME": envDylib.path],
            dataRootProvider: { self.tmp }, bundleResourceURL: nil)
        XCTAssertEqual(got.path, envDylib.path)
    }

    func testResolveEnvInvalidFallsBackToDataRoot() throws {
        let dataRootDylib = touch("drivers/onnxruntime/libonnxruntime.dylib")
        let got = try NativeOnnxRuntime.resolveDylib(
            environment: ["VETARAI_ONNXRUNTIME": tmp.appendingPathComponent("nope.dylib").path],
            dataRootProvider: { self.tmp }, bundleResourceURL: nil)
        XCTAssertEqual(got.path, dataRootDylib.path)
    }

    func testResolveDataRootIsLastResort() throws {
        // env 置空、bundle 目录存在但无 dylib → 落到数据根兜底
        let dataRootDylib = touch("drivers/onnxruntime/libonnxruntime.dylib")
        let bundle = tmp.appendingPathComponent("bundle")
        try FileManager.default.createDirectory(
            at: bundle.appendingPathComponent("onnxruntime"), withIntermediateDirectories: true)
        let got = try NativeOnnxRuntime.resolveDylib(
            environment: [:],
            dataRootProvider: { self.tmp }, bundleResourceURL: bundle)
        XCTAssertEqual(got.path, dataRootDylib.path)
    }

    func testResolveAllMissingThrowsWithTriedList() {
        XCTAssertThrowsError(try NativeOnnxRuntime.resolveDylib(
            environment: ["VETARAI_ONNXRUNTIME": "  "],
            dataRootProvider: { self.tmp }, bundleResourceURL: nil)
        ) { error in
            let msg = (error as? NativeOnnxRuntimeError)?.message ?? ""
            XCTAssertTrue(msg.contains("未找到 onnxruntime 动态库"), msg)
            XCTAssertTrue(msg.contains("VETARAI_ONNXRUNTIME"), msg)
            XCTAssertTrue(msg.contains("已查找"), msg)
            XCTAssertTrue(msg.contains("drivers/onnxruntime/libonnxruntime.dylib"), msg)
        }
    }

    // MARK: - ABI 镜像断言（425 字段 × 8B；关键 idx 钉死）

    func testAbiMirrorLayout() {
        XCTAssertEqual(MemoryLayout<NativeOrtApi>.size, 425 * 8, "OrtApi v29 字段数漂移")
        XCTAssertEqual(MemoryLayout<NativeOrtApi>.stride, 425 * 8)
        XCTAssertEqual(MemoryLayout<NativeOrtApi>.offset(of: \.createEnv), 3 * 8)
        XCTAssertEqual(MemoryLayout<NativeOrtApi>.offset(of: \.createSession), 7 * 8)
        XCTAssertEqual(MemoryLayout<NativeOrtApi>.offset(of: \.run), 9 * 8)
        XCTAssertEqual(MemoryLayout<NativeOrtApi>.offset(of: \.createSessionOptions), 10 * 8)
        XCTAssertEqual(MemoryLayout<NativeOrtApi>.offset(of: \.setSessionGraphOptimizationLevel), 23 * 8)
        XCTAssertEqual(MemoryLayout<NativeOrtApi>.offset(of: \.setIntraOpNumThreads), 24 * 8)
        XCTAssertEqual(MemoryLayout<NativeOrtApi>.offset(of: \.createTensorWithDataAsOrtValue), 49 * 8)
        XCTAssertEqual(MemoryLayout<NativeOrtApi>.offset(of: \.getTensorMutableData), 51 * 8)
        XCTAssertEqual(MemoryLayout<NativeOrtApi>.offset(of: \.getDimensionsCount), 61 * 8)
        XCTAssertEqual(MemoryLayout<NativeOrtApi>.offset(of: \.getDimensions), 62 * 8)
        XCTAssertEqual(MemoryLayout<NativeOrtApi>.offset(of: \.getTensorTypeAndShape), 65 * 8)
        XCTAssertEqual(MemoryLayout<NativeOrtApi>.offset(of: \.createCpuMemoryInfo), 69 * 8)
        XCTAssertEqual(MemoryLayout<NativeOrtApi>.offset(of: \.releaseEnv), 92 * 8)
        XCTAssertEqual(MemoryLayout<NativeOrtApi>.offset(of: \.releaseStatus), 93 * 8)
        XCTAssertEqual(MemoryLayout<NativeOrtApi>.offset(of: \.releaseMemoryInfo), 94 * 8)
        XCTAssertEqual(MemoryLayout<NativeOrtApi>.offset(of: \.releaseSession), 95 * 8)
        XCTAssertEqual(MemoryLayout<NativeOrtApi>.offset(of: \.releaseValue), 96 * 8)
        XCTAssertEqual(MemoryLayout<NativeOrtApi>.offset(of: \.releaseTensorTypeAndShapeInfo), 99 * 8)
        XCTAssertEqual(MemoryLayout<NativeOrtApi>.offset(of: \.releaseSessionOptions), 100 * 8)
    }

    // MARK: - 真 dylib skip-unless 冒烟

    /// 解析候选：env VETARAI_ONNXRUNTIME > 本机 venv 实物（开发机口径）。
    static var realDylibPath: String? {
        if let env = ProcessInfo.processInfo.environment["VETARAI_ONNXRUNTIME"],
           FileManager.default.fileExists(atPath: env) { return env }
        let venv = "/Users/vetar/Desktop/beta/subagent/.venv/lib/python3.14/site-packages/"
            + "onnxruntime/capi/libonnxruntime.1.29.0.dylib"
        return FileManager.default.fileExists(atPath: venv) ? venv : nil
    }

    func testLoadRealDylib() throws {
        let optPath = Self.realDylibPath
        try XCTSkipUnless(optPath != nil,
                          "本机无 onnxruntime dylib（venv 未装），跳过真装载冒烟")
        let rt = try NativeOnnxRuntime.load(path: URL(fileURLWithPath: optPath!))
        XCTAssertEqual(rt.versionString, "1.29.0")
        // CreateEnv 已在 load 内成功（否则早抛）；会话面由端到端测试覆盖
    }

    func testLoadGarbageFileFails() throws {
        let garbage = touch("garbage.dylib")
        XCTAssertThrowsError(try NativeOnnxRuntime.load(path: garbage)) { error in
            let msg = (error as? NativeOnnxRuntimeError)?.message ?? ""
            XCTAssertTrue(msg.contains("动态库加载失败"), msg)
        }
    }
}
