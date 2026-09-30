//
//  NativeAsrFeatureGoldenTests.swift
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

//  硬门槛（P3-W3b 计划）：Swift 特征管线与 Python 参考实现（asr_driver.py）
//  逐阶段比对——预加重后波形 / 加窗后波形 / 功率谱 / mel 谱 / LFR / LFR+CMVN
//  后特征，max abs diff < 1e-4 严容差。
//    ⚠️ 功率谱例外：幅值 ~1e12（int16 刻度 × 512 点 FFT 平方），绝对容差 1e-4
//    相当于相对 1e-16 已跌破 float64 精度——改相对容差 1e-9（函数级注记同款；
//    vDSP zrip 输出 = 2× DFT 的 ×0.25 归一系数由本阶段钉死）。
//  金样来源：Tests/Fixtures/asr/asr_golden.json（generate_asr_fixtures.py 以
//  stub 隔离加载参考实现导出；dither 噪声同文件注入复现 numpy standard_normal）。
//  CTC 合成 logits 与 rich_transcription_postprocess 专例精确串比对。
//

import XCTest
@testable import VetarAINative

final class NativeAsrFeatureGoldenTests: XCTestCase {

    private static let tolerance = 1e-4

    /// 金样 JSON（#filePath = <repo>/Tests/VetarAINativeTests/NativeAsrFeatureGoldenTests.swift）。
    private static func fixtureURL(_ file: StaticString = #filePath) -> URL {
        URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent()   // VetarAINativeTests
            .deletingLastPathComponent()   // Tests
            .appendingPathComponent("Fixtures/asr/asr_golden.json")
    }

    private static func loadFixture() -> [String: Any] {
        let url = fixtureURL()
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("金样 fixture 缺失或损坏: \(url.path)（重跑 generate_asr_fixtures.py）")
            return [:]
        }
        return obj
    }

    private static func doubles(_ obj: [String: Any], _ key: String) -> [Double] {
        (obj[key] as? [NSNumber])?.map(\.doubleValue) ?? []
    }

    private static func maxAbsDiff(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return .infinity }
        var m = 0.0
        for i in 0..<a.count { m = max(m, abs(a[i] - b[i])) }
        return m
    }

    private static func maxRelDiff(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return .infinity }
        var m = 0.0
        for i in 0..<a.count {
            let denom = max(abs(b[i]), 1.0)
            m = max(m, abs(a[i] - b[i]) / denom)
        }
        return m
    }

    // MARK: - 特征管线逐阶段比对

    func testGoldenFeaturePipelineStages() {
        let fx = Self.loadFixture()
        guard !fx.isEmpty else { return }
        let waveform = Self.doubles(fx, "waveform").map { Float($0) }
        let noise = Self.doubles(fx, "dither_noise")
        let sr = (fx["sample_rate"] as? NSNumber)?.intValue ?? 16000
        XCTAssertEqual(waveform.count, 5600)
        XCTAssertEqual(noise.count, 33 * 400)

        let stages = NativeAsrFbankStages()
        let fbank = NativeAsrFeatures.fbank(waveform: waveform, sampleRate: sr,
                                            ditherNoise: noise, stages: stages)

        // ① 预加重后波形（T,400）float64
        let dPre = Self.maxAbsDiff(stages.preemphasisFrames ?? [],
                                   Self.doubles(fx, "preemphasis_frames"))
        XCTAssertLessThan(dPre, Self.tolerance, "预加重后波形 max abs diff=\(dPre)")
        // ② 加窗后波形（T,400）float64
        let dWin = Self.maxAbsDiff(stages.windowedFrames ?? [],
                                   Self.doubles(fx, "windowed_frames"))
        XCTAssertLessThan(dWin, Self.tolerance, "加窗后波形 max abs diff=\(dWin)")
        // ③ 功率谱（T,257）float64——相对容差 1e-9（幅值 ~1e12，见文件头）
        let dPow = Self.maxRelDiff(stages.powerSpectrum ?? [],
                                   Self.doubles(fx, "power_spectrum"))
        XCTAssertLessThan(dPow, 1e-9, "功率谱 max rel diff=\(dPow)")
        // ④ log-mel fbank（T,80）float32
        let dMel = Self.maxAbsDiff(fbank.map { Double($0) },
                                   Self.doubles(fx, "fbank_log_mel"))
        XCTAssertLessThan(dMel, Self.tolerance, "mel 谱 max abs diff=\(dMel)")
        XCTAssertEqual(fbank.count, 33 * 80)

        // ⑤ LFR（T',560）float32
        let lfr = NativeAsrFeatures.applyLfr(feat: fbank, frames: fbank.count / 80)
        let dLfr = Self.maxAbsDiff(lfr.map { Double($0) }, Self.doubles(fx, "lfr"))
        XCTAssertLessThan(dLfr, Self.tolerance, "LFR max abs diff=\(dLfr)")
        XCTAssertEqual(lfr.count, 6 * 560)

        // ⑥ CMVN（T',560）float64
        let cmvnObj = fx["cmvn"] as? [String: Any] ?? [:]
        let cmvn = NativeAsrCmvn(means: Self.doubles(cmvnObj, "means"),
                                 vars: Self.doubles(cmvnObj, "vars"))
        XCTAssertEqual(cmvn.means.count, 560)
        XCTAssertEqual(cmvn.vars.count, 560)
        let cmvned = NativeAsrFeatures.applyCmvn(feat: lfr, dim: 560, cmvn: cmvn)
        let dCmvn = Self.maxAbsDiff(cmvned, Self.doubles(fx, "cmvn_output"))
        XCTAssertLessThan(dCmvn, Self.tolerance, "LFR+CMVN max abs diff=\(dCmvn)")

        // 汇报口径：金样比对最大误差（交付物 #4）
        NSLog("[ASR-GOLDEN] pre=\(dPre) win=\(dWin) pow_rel=\(dPow) mel=\(dMel) "
            + "lfr=\(dLfr) cmvn=\(dCmvn)")
    }

    // MARK: - CTC 合成 logits 对拍

    func testGoldenCtcDecodeCases() {
        let fx = Self.loadFixture()
        guard !fx.isEmpty else { return }
        let cases = fx["ctc_cases"] as? [[String: Any]] ?? []
        XCTAssertEqual(cases.count, 4)
        for (idx, c) in cases.enumerated() {
            let logits = (c["logits"] as? [NSNumber])?.map { Float($0.doubleValue) } ?? []
            let frames = (c["frames"] as? NSNumber)?.intValue ?? 0
            let vocab = (c["vocab"] as? NSNumber)?.intValue ?? 0
            let outLen = (c["out_len"] as? NSNumber)?.intValue ?? 0
            let tokens = c["tokens"] as? [String] ?? []
            let raw = NativeAsrPostprocess.ctcGreedyDecode(
                logits: logits, frames: frames, vocab: vocab, outLen: outLen, tokens: tokens)
            XCTAssertEqual(raw, c["expect_raw"] as? String, "ctc case \(idx) raw")
            let post = NativeAsrPostprocess.richTranscriptionPostprocess(raw)
            XCTAssertEqual(post, c["expect_post"] as? String, "ctc case \(idx) post")
        }
    }

    // MARK: - rich_transcription_postprocess 专例

    func testGoldenPostprocessCases() {
        let fx = Self.loadFixture()
        guard !fx.isEmpty else { return }
        let cases = fx["postprocess_cases"] as? [[String: Any]] ?? []
        XCTAssertEqual(cases.count, 8)
        for (idx, c) in cases.enumerated() {
            let got = NativeAsrPostprocess.richTranscriptionPostprocess(
                c["input"] as? String ?? "<nil>")
            XCTAssertEqual(got, c["expect"] as? String, "postprocess case \(idx)")
        }
    }
}
