//
//  NativeAttachmentEndpointsTests.swift
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

//  逐条对照（⛔ 只读行为规格源）：
//    · app.py L936-975：b64 非法 400 / 10MB 400 / 解析失败 text=nil 不抛 /
//      200k 截断 / C7 归属齐全才落盘 / 落盘失败 save_error 降级不谎称
//    · parser.py L243-279：kind 分类分支序（含 .csv 靠前分流、图片/音频占位）
//    · store.py L653-690：净化（分隔符/控制字符/首尾点空格/≤120 保扩展名）+
//      同名不覆盖 "-<8hex>" 两份保留铁律
//
//  隔离纪律：mktemp 数据根；不打网络不起子进程（.doc textutil 路径已由
//  P2-W1 NativeDocParser package tests 锚定，本文件不重复）。
//

import XCTest
@testable import VetarAINative

final class NativeAttachmentEndpointsTests: XCTestCase {

    private var base: URL!
    private var kernel: NativeKernel!
    private var client: NativeSidecarClient!

    override func setUpWithError() throws {
        try super.setUpWithError()
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("p3w1b_att_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        kernel = NativeKernel(dataRoot: base)
        client = NativeSidecarClient(kernel: kernel)
    }

    override func tearDownWithError() throws {
        client = nil
        kernel = nil
        try? FileManager.default.removeItem(at: base)
        try super.tearDownWithError()
    }

    private var projectsRoot: URL { kernel.database.projectsRoot }

    private func b64(_ s: String) -> String { Data(s.utf8).base64EncodedString() }

    private func parse(_ name: String, _ content: String,
                       pid: String = "", sid: String = "") async throws -> AttachmentParseResult {
        try await client.parseAttachment(name: name, contentBase64: b64(content),
                                         projectId: pid, sessionId: sid)
    }

    // MARK: kind 分类（parser.py L243-279 分支序）

    func testKindClassification() {
        let cases: [(String, String)] = [
            ("a.txt", "text"), ("a.md", "text"), ("a.PY", "text"), ("a.json", "text"),
            ("a.csv", "csv"),                    // .csv 在 TEXT_EXTS 之前分流
            ("a.pdf", "pdf"), ("a.docx", "docx"), ("a.doc", "doc"),
            ("a.xlsx", "xlsx"), ("a.xlsm", "xlsx"), ("a.pptx", "pptx"),
            ("a.png", "image"), ("a.JPG", "image"), ("a.webp", "image"),
            ("a.mp3", "audio"), ("a.m4a", "audio"), ("a.webm", "audio"), ("a.aif", "audio"),
            ("a.bin", "binary"), ("a.zip", "binary"), ("无扩展名", "binary"),
            ("archive.tar.gz", "binary"),        // rfind 末段扩展名
            ("file.", "binary"),                 // _ext_of 逐字：rfind 后 ext="."
        ]
        for (name, kind) in cases {
            XCTAssertEqual(NativeAttachmentEndpoints.kindOf(name), kind, name)
        }
    }

    // MARK: 校验链（400 逐字）

    /// b64 非法 → 400「附件 X 编码非法」；超 10MB → 400「附件 X 超过 10MB 限制」。
    func testValidationChain() async throws {
        // 填充非法（长度 1，Python binascii Invalid padding 同口径）——剥离后仍不可解码
        do {
            _ = try await client.parseAttachment(name: "x.txt", contentBase64: "a",
                                                 projectId: "", sessionId: "")
            XCTFail("应抛 400")
        } catch SidecarError.httpError(let s, let d) {
            XCTAssertEqual(s, 400)
            XCTAssertEqual(d, "附件 x.txt 编码非法")
        }
        // Python validate=False 忽略字母表外字符：夹带空白/换行的合法 b64 应可解
        let r = try await client.parseAttachment(
            name: "x.txt", contentBase64: "aGVs\nbG8= 世界", projectId: "", sessionId: "")
        XCTAssertEqual(r.text, "hello")   // 表外字符剥离后 aGVsbG8= → hello

        // 10MB + 1 字节
        let big = Data(repeating: 0x41, count: 10 * 1024 * 1024 + 1)
        do {
            _ = try await client.parseAttachment(name: "big.bin",
                                                 contentBase64: big.base64EncodedString(),
                                                 projectId: "", sessionId: "")
            XCTFail("应抛 400")
        } catch SidecarError.httpError(let s, let d) {
            XCTAssertEqual(s, 400)
            XCTAssertEqual(d, "附件 big.bin 超过 10MB 限制")
        }
    }

    // MARK: 解析（text/csv/占位/失败不抛）

    /// .txt utf-8；gbk 编码回退；.csv 行拼接；图片/音频/未知两段式占位；
    /// 解析失败（垃圾 PDF）text=nil 不抛。
    func testParsePaths() async throws {
        let txt = try await parse("笔记.txt", "第一行\n第二行")
        XCTAssertEqual(txt.name, "笔记.txt")
        XCTAssertEqual(txt.kind, "text")
        XCTAssertEqual(txt.text, "第一行\n第二行")
        XCTAssertFalse(txt.truncated)

        // gbk（GB_18030_2000 超集口径，Python gbk codec 近似）
        let gbk = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        let gbkData = "中文内容".data(using: gbk)!
        let r2 = try await client.parseAttachment(name: "g.txt",
                                                  contentBase64: gbkData.base64EncodedString(),
                                                  projectId: "", sessionId: "")
        XCTAssertEqual(r2.text, "中文内容")

        let csv = try await parse("t.csv", "a,b,c\n1,2,3")
        XCTAssertEqual(csv.kind, "csv")
        XCTAssertEqual(csv.text, "a | b | c\n1 | 2 | 3")

        let img = try await client.parseAttachment(
            name: "p.png", contentBase64: Data([0x89, 0x50, 0x4E, 0x47]).base64EncodedString(),
            projectId: "", sessionId: "")
        XCTAssertEqual(img.kind, "image")
        XCTAssertNil(img.text)

        let aud = try await client.parseAttachment(
            name: "a.mp3", contentBase64: Data([0xFF, 0xFB]).base64EncodedString(),
            projectId: "", sessionId: "")
        XCTAssertEqual(aud.kind, "audio")
        XCTAssertNil(aud.text)

        let bin = try await client.parseAttachment(
            name: "x.bin", contentBase64: Data([0x00, 0x01, 0x02]).base64EncodedString(),
            projectId: "", sessionId: "")
        XCTAssertEqual(bin.kind, "binary")
        XCTAssertNil(bin.text)

        // 解析失败（垃圾 PDF）→ text=nil 不抛（端点 docstring：无法解析 → text=null）
        let badPDF = try await client.parseAttachment(
            name: "bad.pdf", contentBase64: b64("这不是 PDF"), projectId: "", sessionId: "")
        XCTAssertEqual(badPDF.kind, "pdf")
        XCTAssertNil(badPDF.text)
    }

    // MARK: 200k 截断

    /// 单件 200k 字符截断（truncated=true；恰好 200k 不截）。
    func testTruncation() async throws {
        let over = String(repeating: "字", count: 200_500)
        let r = try await parse("长.txt", over)
        XCTAssertTrue(r.truncated)
        XCTAssertEqual(r.text?.unicodeScalars.count, 200_000)

        let exact = String(repeating: "x", count: 200_000)
        let r2 = try await parse("齐.txt", exact)
        XCTAssertFalse(r2.truncated)
        XCTAssertEqual(r2.text?.count, 200_000)
    }

    // MARK: C7 落盘（归属/净化/同名铁律/save_error 降级）

    /// pid+sid 齐全 → 落盘回传绝对路径、内容一致；缺归属/空内容 → 不落盘且无错。
    func testSaveSemantics() async throws {
        let r = try await parse("报告.txt", "落盘内容", pid: "p1", sid: "s1")
        let saved = try XCTUnwrap(r.savedPath)
        XCTAssertNil(r.saveError)
        XCTAssertEqual(saved, projectsRoot.appendingPathComponent(
            "p1/attachments/s1/报告.txt").path)
        XCTAssertEqual(try String(contentsOfFile: saved, encoding: .utf8), "落盘内容")

        // 缺 sid（新会话未创建）→ 只解析不落盘，不算错误
        let r2 = try await parse("报告.txt", "只解析", pid: "p1", sid: "")
        XCTAssertNil(r2.savedPath)
        XCTAssertNil(r2.saveError)
        // 空内容 → `if pid and sid and raw:` 不成立，不落盘
        let r3 = try await client.parseAttachment(name: "空.txt", contentBase64: "",
                                                  projectId: "p1", sessionId: "s1")
        XCTAssertNil(r3.savedPath)
        XCTAssertNil(r3.saveError)
    }

    /// 净化：路径穿越只取末段；控制字符剔除；".." → "attachment"；超长保扩展名。
    func testSanitize() {
        XCTAssertEqual(NativeAttachmentEndpoints.sanitizeAttachmentName("../../etc/passwd"),
                       "passwd")
        XCTAssertEqual(NativeAttachmentEndpoints.sanitizeAttachmentName("..\\..\\win.exe"),
                       "win.exe")
        XCTAssertEqual(NativeAttachmentEndpoints.sanitizeAttachmentName("a\0b\u{1F}c.txt"),
                       "abc.txt")
        XCTAssertEqual(NativeAttachmentEndpoints.sanitizeAttachmentName(".."), "attachment")
        XCTAssertEqual(NativeAttachmentEndpoints.sanitizeAttachmentName("  .  "), "attachment")
        XCTAssertEqual(NativeAttachmentEndpoints.sanitizeAttachmentName(""), "attachment")
        // 超长：保扩展名截到 120 码点
        let longStem = String(repeating: "长", count: 200)
        let sanitized = NativeAttachmentEndpoints.sanitizeAttachmentName("\(longStem).txt")
        XCTAssertEqual(sanitized.unicodeScalars.count, 120)
        XCTAssertTrue(sanitized.hasSuffix(".txt"))
        // 无扩展名超长：直接截 120
        let noExt = NativeAttachmentEndpoints.sanitizeAttachmentName(String(repeating: "a", count: 130))
        XCTAssertEqual(noExt.count, 120)
    }

    /// 同名不覆盖：第二份 "-<8hex>" 后缀，两份都保留且内容各自正确。
    func testCollisionKeepsBoth() async throws {
        let r1 = try await parse("重名.txt", "第一版", pid: "p1", sid: "s1")
        let r2 = try await parse("重名.txt", "第二版", pid: "p1", sid: "s1")
        let p1 = try XCTUnwrap(r1.savedPath)
        let p2 = try XCTUnwrap(r2.savedPath)
        XCTAssertEqual((p1 as NSString).lastPathComponent, "重名.txt")
        XCTAssertNotEqual(p1, p2)
        XCTAssertTrue((p2 as NSString).lastPathComponent
            .range(of: #"^重名-[0-9a-f]{8}\.txt$"#, options: .regularExpression) != nil,
                      "uuid4().hex[:8] 小写后缀：\((p2 as NSString).lastPathComponent)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: p1), "第一份保留（用户铁律）")
        XCTAssertEqual(try String(contentsOfFile: p1, encoding: .utf8), "第一版")
        XCTAssertEqual(try String(contentsOfFile: p2, encoding: .utf8), "第二版")
    }

    /// 落盘失败降级为只解析：附件目录路径被同名文件占用 → savedPath=nil +
    /// saveError 以 "OSError: " 前缀如实告知（解析价值不受影响）。
    func testSaveErrorDegradation() async throws {
        // 在 p2/attachments 处放一个**文件**，mkdir 必失败
        let p2 = projectsRoot.appendingPathComponent("p2")
        try FileManager.default.createDirectory(at: p2, withIntermediateDirectories: true)
        try "占用".write(to: p2.appendingPathComponent("attachments"),
                        atomically: false, encoding: .utf8)
        let r = try await parse("ok.txt", "内容", pid: "p2", sid: "s1")
        XCTAssertEqual(r.text, "内容", "落盘失败不得让解析失败")
        XCTAssertNil(r.savedPath)
        XCTAssertTrue(r.saveError?.hasPrefix("OSError: ") ?? false,
                      "save_error 形态对齐 f\"{type(e).__name__}: {e}\"：\(r.saveError ?? "nil")")
    }
}
