//
//  NativeSkillsTests.swift
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

//  逐条对照 subagent/sidecar/skills_mgr/manager.py（⛔ 只读行为规格源）与
//  subagent/sidecar/skills_mgr/test_skills.py + loop.py read_skill 路由段（L1448-1462）：
//    · A 组：frontmatter 解析/构建（无/未闭合降级、引号剥离、键白名单正则）
//    · B 组：_valid_skill_name（字母/数字/中文/-/_，1-64 字符；路径字符拒绝）
//    · C 组：创建/读取/更新（描述换行→空格 + 500 截断；frontmatter 三字段）
//    · D 组：list_skills / build_skills_list_text（仅启用项；无描述回落；空清单空串）
//    · E 组：enabled 三态（false/0/no → 禁用；缺省/其它 → 启用）
//    · F 组：toggle（返回新状态；禁用仍可读；缺 name 键补 setdefault；不存在 → nil）
//    · G 组：delete（真删；重复删 False）
//    · H 组：NativeAgentLoop.routeReadSkill 路由语义（不存在列可用清单 / 已禁用 /
//      成功 _kind / 空 name / 未装配如实报错）——Python loop.py L1449-1462 逐行
//
//  ⚠️VERIFY 未翻：install_skill_from_repo（W4c 范围外，git clone 通道由 W3a
//  NativeToolInstall 承接，见 NativeSkills.swift 头注）。
//
//  隔离纪律：mktemp 全真文件隔离（NativeSkillsManager(skillsRoot:) 指向临时目录）；
//  不起网络/模型；不触真实数据目录。
//

import XCTest
@testable import VetarAINative

final class NativeSkillsTests: XCTestCase {

    private var tmp: URL!
    private var mgr: NativeSkillsManager!

    override func setUp() async throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("p2w4c_skills_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        mgr = NativeSkillsManager(skillsRoot: tmp.appendingPathComponent("skills", isDirectory: true))
    }

    override func tearDown() {
        if let tmp { try? FileManager.default.removeItem(at: tmp) }
        mgr = nil
        super.tearDown()
    }

    /// 直接落一个 SKILL.md（模拟用户手工放置的技能目录）。
    private func placeSkill(_ dir: String, _ text: String) throws {
        let d = mgr.skillsRoot.appendingPathComponent(dir, isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        try text.write(to: d.appendingPathComponent("SKILL.md"), atomically: false, encoding: .utf8)
    }

    // ════════════════════════ A 组：frontmatter 解析/构建 ════════════════════════

    /// A1：标准 frontmatter 解析（Python test 1a）。
    func testA1_parseFrontmatterStandard() {
        let (meta, body) = NativeSkillsManager.parseFrontmatter(
            "---\nname: demo\ndescription: 示例技能\nenabled: true\n---\n\n正文内容")
        XCTAssertEqual(meta, ["name": "demo", "description": "示例技能", "enabled": "true"])
        XCTAssertEqual(body.trimmingCharacters(in: .whitespacesAndNewlines), "正文内容")
    }

    /// A2：无 frontmatter → 空 meta + 原文（Python test 1b）。
    func testA2_parseFrontmatterAbsent() {
        let (meta, body) = NativeSkillsManager.parseFrontmatter("无 frontmatter 的纯文本")
        XCTAssertTrue(meta.isEmpty)
        XCTAssertEqual(body, "无 frontmatter 的纯文本")
    }

    /// A3：未闭合 frontmatter → 空 meta + 原文（Python test 1c）。
    func testA3_parseFrontmatterUnclosed() {
        let (meta, body) = NativeSkillsManager.parseFrontmatter("---\nname: x\n没有闭合")
        XCTAssertTrue(meta.isEmpty)
        XCTAssertEqual(body, "---\nname: x\n没有闭合")
    }

    /// A4：值两端成对引号剥离（Python .strip('"').strip("'")）；非法键行跳过。
    func testA4_parseFrontmatterQuoteStripAndBadLines() {
        let (meta, _) = NativeSkillsManager.parseFrontmatter(
            "---\nname: \"引号名\"\ndescription: '单引号述'\n不算键值对\n9bad: 数字键\n---\nb")
        XCTAssertEqual(meta["name"], "引号名")
        XCTAssertEqual(meta["description"], "单引号述")
        XCTAssertNil(meta["不算键值对"])
        XCTAssertNil(meta["9bad"])   // 键须 [A-Za-z_][\w-]*，数字开头不匹配
    }

    /// A5：build 与 parse 互逆（_build_frontmatter 行序保持）。
    func testA5_buildFrontmatterRoundtrip() {
        let fm = NativeSkillsManager.buildFrontmatter(
            [("name", "x"), ("description", "d"), ("enabled", "false")])
        XCTAssertEqual(fm, "---\nname: x\ndescription: d\nenabled: false\n---")
        let (meta, _) = NativeSkillsManager.parseFrontmatter(fm + "\n\nbody")
        XCTAssertEqual(meta, ["name": "x", "description": "d", "enabled": "false"])
    }

    // ════════════════════════ B 组：_valid_skill_name ════════════════════════

    /// B1：合法名（中文/字母/数字/-/_ 组合）。
    func testB1_validSkillNames() {
        for n in ["周报助手", "translate-en", "a_b-c9", "纯中文技能", "x", String(repeating: "a", count: 64)] {
            XCTAssertTrue(NativeSkillsManager.isValidSkillName(n), "应合法：\(n)")
        }
    }

    /// B2：非法名（空/超长/路径字符/空格/点号）。
    func testB2_invalidSkillNames() {
        for n in ["", String(repeating: "a", count: 65), "../evil", "a/b", "a b", "a.b", "技能!", "a\\b"] {
            XCTAssertFalse(NativeSkillsManager.isValidSkillName(n), "应非法：\(n)")
        }
    }

    // ════════════════════════ C 组：创建/读取/更新 ════════════════════════

    /// C1：创建→读取回环（Python test 2a/2b）：名称/描述/正文/启用。
    func testC1_createAndRead() throws {
        XCTAssertTrue(mgr.createOrUpdateSkill("周报助手", description: "按模板生成周报",
                                              body: "# 步骤\n1. 收集数据", enabled: true))
        let sk = try XCTUnwrap(mgr.readSkill("周报助手"))
        XCTAssertEqual(sk.dirName, "周报助手")
        XCTAssertEqual(sk.description, "按模板生成周报")
        XCTAssertTrue(sk.content.contains("收集数据"), sk.content)
        XCTAssertTrue(sk.enabled)
    }

    /// C2：非法名拒绝（Python test 2c/2d）；读不存在 → nil（test 2e）。
    func testC2_illegalNameAndMissing() {
        XCTAssertFalse(mgr.createOrUpdateSkill("../evil", description: "x", body: "y"))
        XCTAssertFalse(mgr.createOrUpdateSkill(String(repeating: "a", count: 65),
                                               description: "x", body: "y"))
        XCTAssertNil(mgr.readSkill("不存在"))
    }

    /// C3：描述换行→空格 + 超 500 字符截断（manager.py L147）。
    func testC3_descriptionSanitized() throws {
        let longDesc = "第一行\n第二行" + String(repeating: "长", count: 600)
        XCTAssertTrue(mgr.createOrUpdateSkill("长描述", description: longDesc, body: "b"))
        let sk = try XCTUnwrap(mgr.readSkill("长描述"))
        XCTAssertFalse(sk.description.contains("\n"))
        XCTAssertTrue(sk.description.contains("第一行 第二行"))
        XCTAssertEqual(sk.description.unicodeScalars.count, 500)
    }

    /// C4：更新覆盖（Python test 5a）。
    func testC4_updateOverwrites() throws {
        XCTAssertTrue(mgr.createOrUpdateSkill("周报助手", description: "旧", body: "旧正文", enabled: true))
        XCTAssertTrue(mgr.createOrUpdateSkill("周报助手", description: "新描述", body: "新正文", enabled: true))
        let sk = try XCTUnwrap(mgr.readSkill("周报助手"))
        XCTAssertEqual(sk.description, "新描述")
        XCTAssertTrue(sk.content.contains("新正文"), sk.content)
    }

    /// C5：创建出的文件 frontmatter 三字段齐（name/description/enabled）。
    func testC5_createdFileShape() throws {
        XCTAssertTrue(mgr.createOrUpdateSkill("shape", description: "d", body: "正文", enabled: false))
        let text = try String(contentsOf: mgr.skillsRoot
            .appendingPathComponent("shape/SKILL.md"), encoding: .utf8)
        XCTAssertTrue(text.hasPrefix("---\nname: shape\ndescription: d\nenabled: false\n---\n\n正文"),
                      text)
    }

    // ════════════════════════ D 组：list / 清单文本 ════════════════════════

    /// D1：list_skills 字段齐（name 回落 dir_name；path 指向 SKILL.md）。
    func testD1_listSkillsFields() throws {
        try placeSkill("raw-dir", "---\ndescription: 有描述\n---\n正文")
        XCTAssertTrue(mgr.createOrUpdateSkill("有名字", description: "按模板", body: "b", enabled: true))
        let lst = mgr.listSkills()
        XCTAssertEqual(lst.count, 2)
        let raw = try XCTUnwrap(lst.first { $0.dirName == "raw-dir" })
        XCTAssertEqual(raw.name, "raw-dir")            // meta 无 name → 回落 dir_name
        XCTAssertEqual(raw.skillDescription, "有描述")
        XCTAssertTrue(raw.enabled)                     // 缺省 enabled → true
        XCTAssertTrue(raw.path.hasSuffix("raw-dir/SKILL.md"), raw.path)
        let named = try XCTUnwrap(lst.first { $0.dirName == "有名字" })
        XCTAssertEqual(named.name, "有名字")
    }

    /// D2：build_skills_list_text 仅启用项（Python test 3b）；无描述回落「（无描述）」。
    func testD2_buildListText() throws {
        XCTAssertTrue(mgr.createOrUpdateSkill("周报助手", description: "按模板生成周报",
                                              body: "b", enabled: true))
        try placeSkill("无述", "---\nname: 无述\n---\nb")
        let text = mgr.buildSkillsListText()
        XCTAssertTrue(text.contains("- 周报助手：按模板生成周报"), text)
        XCTAssertTrue(text.contains("- 无述：（无描述）"), text)
    }

    /// D3：无启用项 → 空串（manager.py L262）。
    func testD3_buildListTextEmptyWhenNoneEnabled() throws {
        XCTAssertEqual(mgr.buildSkillsListText(), "")
        try placeSkill("禁用项", "---\nname: 禁用项\nenabled: false\n---\nb")
        XCTAssertEqual(mgr.buildSkillsListText(), "")
    }

    /// D4：目录里无 SKILL.md 的目录与杂散文件不进入列表。
    func testD4_listSkipsNonSkillEntries() throws {
        try FileManager.default.createDirectory(
            at: mgr.skillsRoot.appendingPathComponent("空目录"), withIntermediateDirectories: true)
        try "垃圾".write(to: mgr.skillsRoot.appendingPathComponent("readme.txt"),
                         atomically: false, encoding: .utf8)
        XCTAssertTrue(mgr.createOrUpdateSkill("真技能", description: "d", body: "b", enabled: true))
        XCTAssertEqual(mgr.listSkills().map { $0.dirName }, ["真技能"])
    }

    // ════════════════════════ E 组：enabled 三态 ════════════════════════

    /// E1：false/0/no（含大小写与空白）→ 禁用；缺省/其它 → 启用（manager.py L108-113）。
    func testE1_enabledTristate() throws {
        for (raw, expect) in [("false", false), ("0", false), ("no", false),
                              ("False", false), (" NO ", false), ("true", true), ("yes", true)] {
            let dir = "e-\(raw.replacingOccurrences(of: " ", with: "_"))"
            try placeSkill(dir, "---\nname: \(dir)\nenabled: \(raw)\n---\nb")
            let sk = try XCTUnwrap(mgr.readSkill(dir), "raw=\(raw)")
            XCTAssertEqual(sk.enabled, expect, "enabled=\(raw) 应为 \(expect)")
        }
        try placeSkill("e-missing", "---\nname: e-missing\n---\nb")
        XCTAssertTrue(try XCTUnwrap(mgr.readSkill("e-missing")).enabled)
    }

    // ════════════════════════ F 组：toggle ════════════════════════

    /// F1：toggle 返回新状态；禁用后清单不含、read 仍可读（Python test 4a-4c）。
    func testF1_toggleRoundtrip() throws {
        XCTAssertTrue(mgr.createOrUpdateSkill("翻译", description: "中英互译", body: "翻译指令",
                                              enabled: true))
        XCTAssertEqual(mgr.toggleSkill("翻译"), false)
        let text = mgr.buildSkillsListText()
        XCTAssertFalse(text.contains("翻译"), text)
        let sk = try XCTUnwrap(mgr.readSkill("翻译"))   // 禁用技能仍可读取（enabled=False）
        XCTAssertFalse(sk.enabled)
        XCTAssertEqual(mgr.toggleSkill("翻译"), true)   // 恢复
        XCTAssertTrue(try XCTUnwrap(mgr.readSkill("翻译")).enabled)
    }

    /// F2：toggle 不存在/非法名 → nil（manager.py L172-175）。
    func testF2_toggleMissing() {
        XCTAssertNil(mgr.toggleSkill("不存在"))
        XCTAssertNil(mgr.toggleSkill("../evil"))
    }

    /// F3：toggle 缺 name 键的技能 → setdefault 补 name（manager.py L181），正文不丢。
    func testF3_toggleBackfillsName() throws {
        try placeSkill("无名", "---\ndescription: 只有描述\nenabled: true\n---\n\n正文行")
        XCTAssertEqual(mgr.toggleSkill("无名"), false)
        let sk = try XCTUnwrap(mgr.readSkill("无名"))
        XCTAssertFalse(sk.enabled)
        XCTAssertEqual(sk.description, "只有描述")
        XCTAssertTrue(sk.content.contains("正文行"), sk.content)
        // 文件内已补 name 键
        let raw = try String(contentsOf: mgr.skillsRoot.appendingPathComponent("无名/SKILL.md"),
                             encoding: .utf8)
        XCTAssertTrue(raw.contains("name: 无名"), raw)
    }

    // ════════════════════════ G 组：delete ════════════════════════

    /// G1：删除→读取 nil；重复删 False（Python test 7a-7c）。
    func testG1_delete() {
        XCTAssertTrue(mgr.createOrUpdateSkill("翻译", description: "d", body: "b", enabled: true))
        XCTAssertTrue(mgr.deleteSkill("翻译"))
        XCTAssertNil(mgr.readSkill("翻译"))
        XCTAssertFalse(mgr.deleteSkill("翻译"))
        XCTAssertFalse(mgr.deleteSkill("../evil"))
    }

    // ════════════════════════ H 组：routeReadSkill 路由语义 ════════════════════════

    /// H1：成功 → ok + _kind=read_skill + name/description/content（loop.py L1460-1462）。
    func testH1_routeReadSkillSuccess() throws {
        XCTAssertTrue(mgr.createOrUpdateSkill("周报助手", description: "按模板", body: "详细指令",
                                              enabled: true))
        let r = NativeAgentLoop.routeReadSkill(args: ["name": .string("周报助手")], reader: mgr)
        XCTAssertEqual(r["ok"], .bool(true))
        XCTAssertEqual(r["_kind"], .string("read_skill"))
        XCTAssertEqual(r["name"], .string("周报助手"))
        XCTAssertEqual(r["description"], .string("按模板"))
        XCTAssertEqual(r["content"], .string("详细指令"))
    }

    /// H2：不存在 → ok=false 且列出当前可用技能（loop.py L1453-1455）。
    func testH2_routeReadSkillMissingListsAvailable() throws {
        XCTAssertTrue(mgr.createOrUpdateSkill("甲技能", description: "d", body: "b", enabled: true))
        XCTAssertTrue(mgr.createOrUpdateSkill("乙技能", description: "d", body: "b", enabled: true))
        let r = NativeAgentLoop.routeReadSkill(args: ["name": .string("不存在")], reader: mgr)
        XCTAssertEqual(r["ok"], .bool(false))
        let e = try XCTUnwrap(r["error"]?.string)
        XCTAssertTrue(e.contains("技能不存在：不存在"), e)
        XCTAssertTrue(e.contains("甲技能") && e.contains("乙技能"), e)
    }

    /// H3：空库时不存在 → 「（暂无技能）」（loop.py L1454）。
    func testH3_routeReadSkillMissingEmptyLibrary() throws {
        let r = NativeAgentLoop.routeReadSkill(args: ["name": .string("x")], reader: mgr)
        XCTAssertEqual(r["ok"], .bool(false))
        XCTAssertTrue(try XCTUnwrap(r["error"]?.string).contains("（暂无技能）"))
    }

    /// H4：禁用技能 → 逐项开关报错（checkpoint-047；loop.py L1456-1458）。
    func testH4_routeReadSkillDisabled() throws {
        XCTAssertTrue(mgr.createOrUpdateSkill("翻译", description: "d", body: "b", enabled: false))
        let r = NativeAgentLoop.routeReadSkill(args: ["name": .string("翻译")], reader: mgr)
        XCTAssertEqual(r["ok"], .bool(false))
        let e = try XCTUnwrap(r["error"]?.string)
        XCTAssertTrue(e.contains("技能「翻译」已被禁用"), e)
    }

    /// H5：空 name 参数 → 走不存在分支（Python `_read_skill(_sname) if _sname else None`）。
    func testH5_routeReadSkillEmptyName() throws {
        XCTAssertTrue(mgr.createOrUpdateSkill("甲", description: "d", body: "b", enabled: true))
        let r = NativeAgentLoop.routeReadSkill(args: ["name": .string("  ")], reader: mgr)
        XCTAssertEqual(r["ok"], .bool(false))
        XCTAssertTrue(try XCTUnwrap(r["error"]?.string).contains("技能不存在"))
    }

    /// H6：reader 未装配 → 如实报错（W4c 起原生接管，nil 属装配缺失，不静默吞）。
    func testH6_routeReadSkillNoReader() throws {
        let r = NativeAgentLoop.routeReadSkill(args: ["name": .string("x")], reader: nil)
        XCTAssertEqual(r["ok"], .bool(false))
        XCTAssertTrue(try XCTUnwrap(r["error"]?.string).contains("未装配"))
    }
}
