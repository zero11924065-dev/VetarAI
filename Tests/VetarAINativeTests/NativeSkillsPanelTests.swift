//
//  NativeSkillsPanelTests.swift
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

//  逐条对照 app.py L2114-2164 七端点 + skills_mgr/manager.py（⛔ 只读行为规格源）：
//    · GET /api/skills：SkillItem 五字段（name 取 frontmatter / 回落目录名；path 绝对路径）
//    · GET /api/skills/{name}：SkillDetail 含 content；name 取 frontmatter；
//      不存在/非法名 → 404「技能不存在」
//    · POST /api/skills：非法名 → 400「技能名非法（限字母/数字/中文/-/_，≤64 字符）」
//    · PUT /api/skills/{name}：失败 → 400「更新失败」
//    · DELETE /api/skills/{name}：false → 404「技能不存在或名称非法」
//    · POST …/toggle：返回新状态；不存在 → 400「切换失败（技能不存在）」
//    · POST /api/skills/install：本地目录直拷成功；缺 SKILL.md/已存在/非法名/空地址
//      → 400 + result.error 原文案（git 远程克隆分支由 W3a NativeToolInstallTests 锚定，
//      本文件不打真网络）
//    · 技能写端点无 SSE notify（app.py 逐字核对）——原生总线零事件锚定
//
//  隔离纪律：mktemp 数据根全真文件隔离；历史上 fallback = MockSidecarClient（未实现
//  KnowledgePanelClient，任何 HTTP 回落即 decodeFailed 显形）。
//

import XCTest
@testable import VetarAINative

final class NativeSkillsPanelTests: XCTestCase {

    private var base: URL!
    private var kernel: NativeKernel!
    private var client: NativeSidecarClient!

    override func setUpWithError() throws {
        try super.setUpWithError()
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("p3w1b_skills_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        kernel = NativeKernel(dataRoot: base)
        client = NativeSidecarClient(kernel: kernel)
        NativeAppEvents.clearAll()
    }

    override func tearDownWithError() throws {
        NativeAppEvents.clearAll()
        client = nil
        kernel = nil
        try? FileManager.default.removeItem(at: base)
        try super.tearDownWithError()
    }

    /// 直接落一个 SKILL.md（模拟已安装技能）。
    private func placeSkill(_ dir: String, _ text: String) throws {
        let d = kernel.skillsManager.skillsRoot.appendingPathComponent(dir, isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        try text.write(to: d.appendingPathComponent("SKILL.md"), atomically: false, encoding: .utf8)
    }

    private func assertHTTPError(_ status: Int, _ detail: String,
                                 _ work: () async throws -> some Any,
                                 file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await work()
            XCTFail("应抛 httpError(\(status))：\(detail)", file: file, line: line)
        } catch SidecarError.httpError(let s, let d) {
            XCTAssertEqual(s, status, file: file, line: line)
            XCTAssertEqual(d, detail, file: file, line: line)
        } catch {
            XCTFail("错误类型不符：\(error)", file: file, line: line)
        }
    }

    // MARK: GET /api/skills（列表形态）

    /// 列表：name 取 frontmatter name；无 frontmatter 回落目录名；path = 绝对 SKILL.md 路径。
    func testListSkillsShape() async throws {
        try placeSkill("demo", "---\nname: 显示名\ndescription: 示例描述\nenabled: false\n---\n\n正文")
        try placeSkill("plain", "无 frontmatter 正文")
        let items = try await client.listSkills()
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].dir_name, "demo")
        XCTAssertEqual(items[0].name, "显示名")
        XCTAssertEqual(items[0].description, "示例描述")
        XCTAssertFalse(items[0].enabled)
        XCTAssertTrue(items[0].path?.hasSuffix("demo/SKILL.md") ?? false)
        XCTAssertEqual(items[1].dir_name, "plain")
        XCTAssertEqual(items[1].name, "plain")           // meta.get("name", d.name) 回落
        XCTAssertEqual(items[1].description, "")
        XCTAssertTrue(items[1].enabled)                  // enabled 缺省 true
    }

    // MARK: GET /api/skills/{name}（详情形态）

    /// 详情：五字段齐全（含正文 strip）；frontmatter name 优先。
    func testReadSkillShape() async throws {
        try placeSkill("demo", "---\nname: 显示名\ndescription: d\nenabled: true\n---\n\n  正文内容  \n")
        let d = try await client.readSkill(dirName: "demo")
        XCTAssertEqual(d.name, "显示名")
        XCTAssertEqual(d.dir_name, "demo")
        XCTAssertEqual(d.description, "d")
        XCTAssertTrue(d.enabled)
        XCTAssertEqual(d.content, "正文内容")
    }

    /// 不存在 → 404「技能不存在」；非法名（路径穿越）→ 同 404（manager 返回 None 口径）。
    func testReadSkillNotFound() async throws {
        await assertHTTPError(404, "技能不存在") { try await client.readSkill(dirName: "ghost") }
        await assertHTTPError(404, "技能不存在") { try await client.readSkill(dirName: "../etc") }
    }

    // MARK: POST /api/skills（新建）

    /// 新建成功 → 落盘可读回；非法名 → 400 原文案逐字。
    func testCreateSkill() async throws {
        try await client.createSkill(name: "新技能-1", description: "描述\n换行", body: "正文", enabled: true)
        let d = try await client.readSkill(dirName: "新技能-1")
        XCTAssertEqual(d.description, "描述 换行")        // replace("\n"," ")
        XCTAssertEqual(d.content, "正文")
        await assertHTTPError(400, "技能名非法（限字母/数字/中文/-/_，≤64 字符）") {
            try await client.createSkill(name: "非法/名", description: "", body: "", enabled: true)
        }
        await assertHTTPError(400, "技能名非法（限字母/数字/中文/-/_，≤64 字符）") {
            try await client.createSkill(name: String(repeating: "a", count: 65),
                                         description: "", body: "", enabled: true)
        }
    }

    // MARK: PUT /api/skills/{name}（更新）

    /// 更新成功改描述/正文/启停；非法名 → 400「更新失败」。
    func testUpdateSkill() async throws {
        try await client.createSkill(name: "demo", description: "旧", body: "旧文", enabled: true)
        try await client.updateSkill(dirName: "demo", description: "新", body: "新文", enabled: false)
        let d = try await client.readSkill(dirName: "demo")
        XCTAssertEqual(d.description, "新")
        XCTAssertEqual(d.content, "新文")
        XCTAssertFalse(d.enabled)
        await assertHTTPError(400, "更新失败") {
            try await client.updateSkill(dirName: "非法/名", description: "", body: "", enabled: true)
        }
    }

    // MARK: DELETE /api/skills/{name}

    /// 真删；重复删 → 404「技能不存在或名称非法」。
    func testDeleteSkill() async throws {
        try await client.createSkill(name: "demo", description: "", body: "", enabled: true)
        try await client.deleteSkill(dirName: "demo")
        let remaining = try await client.listSkills()
        XCTAssertTrue(remaining.isEmpty)
        await assertHTTPError(404, "技能不存在或名称非法") {
            try await client.deleteSkill(dirName: "demo")
        }
    }

    // MARK: POST …/toggle

    /// 返回新状态（启用→禁用返 false，再切返 true）；不存在 → 400 原文案。
    func testToggleSkill() async throws {
        try await client.createSkill(name: "demo", description: "", body: "", enabled: true)
        let s1 = try await client.toggleSkill(dirName: "demo")
        XCTAssertFalse(s1)
        let afterToggle = try await client.readSkill(dirName: "demo")
        XCTAssertFalse(afterToggle.enabled)
        let s2 = try await client.toggleSkill(dirName: "demo")
        XCTAssertTrue(s2)
        await assertHTTPError(400, "切换失败（技能不存在）") {
            try await client.toggleSkill(dirName: "ghost")
        }
    }

    // MARK: POST /api/skills/install（本地路径分支；远程 git 分支 W3a 已锚定）

    /// 本地目录直拷成功：SKILL.md 在子目录时 rglob 定位；frontmatter 取名；copytree 全目录。
    func testInstallSkillFromLocalDir() async throws {
        let src = base.appendingPathComponent("src_repo")
        let nested = src.appendingPathComponent("pack/my-skill", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try "---\nname: 安装技\ndescription: 本地装\n---\n\n正文".write(
            to: nested.appendingPathComponent("SKILL.md"), atomically: false, encoding: .utf8)
        try "附带文件".write(to: nested.appendingPathComponent("extra.txt"),
                            atomically: false, encoding: .utf8)

        try await client.installSkill(url: src.path)
        let d = try await client.readSkill(dirName: "安装技")
        XCTAssertEqual(d.description, "本地装")
        // copytree 语义：整目录（含 extra.txt）拷到 skills/<name>/
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: kernel.skillsManager.skillsRoot
                .appendingPathComponent("安装技/extra.txt").path))

        // 已存在 → 400「技能已存在: <name>」
        await assertHTTPError(400, "技能已存在: 安装技") {
            try await client.installSkill(url: src.path)
        }
        // 空地址 → 400「地址不能为空」
        await assertHTTPError(400, "地址不能为空") {
            try await client.installSkill(url: "   ")
        }
        // 无 SKILL.md → 400 原文案
        let empty = base.appendingPathComponent("empty_dir")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        await assertHTTPError(400, "该目录内未找到 SKILL.md") {
            try await client.installSkill(url: empty.path)
        }
        // frontmatter 名非法 → 400「技能名非法: <name>」
        let bad = base.appendingPathComponent("bad_repo")
        try FileManager.default.createDirectory(at: bad, withIntermediateDirectories: true)
        try "---\nname: 非法/名\n---\n".write(to: bad.appendingPathComponent("SKILL.md"),
                                            atomically: false, encoding: .utf8)
        await assertHTTPError(400, "技能名非法: 非法/名") {
            try await client.installSkill(url: bad.path)
        }
    }

    // MARK: 技能写端点无 SSE notify（app.py L2114-2164 逐字核对：零 _notify_change）

    /// 全部写路径走完后原生总线零事件（对照 knowledge 写有 A13——技能逐字不发）。
    func testSkillWritesEmitNoEvents() async throws {
        try await client.createSkill(name: "demo", description: "", body: "", enabled: true)
        try await client.updateSkill(dirName: "demo", description: "d", body: "", enabled: true)
        _ = try await client.toggleSkill(dirName: "demo")
        try await client.deleteSkill(dirName: "demo")
        XCTAssertEqual(NativeAppEvents.latestSeq(), 0,
                       "技能写端点不应产生任何资源变更事件")
    }
}
