//
//  NativeSkills.swift
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

//  逐行为移植 subagent/sidecar/skills_mgr/manager.py（⛔ 只读行为规格源，266 行；
//  语义分歧以 Python 源码为准）：
//    · skills_root() = <data_root>/skills/（mkdir 副作用对齐）
//    · _valid_skill_name：字母/数字/中文/-/_，1-64 字符（\w 全字匹配）
//    · _parse_frontmatter / _build_frontmatter（`---` 简易解析，不引 YAML 依赖）
//    · list_skills / read_skill（frontmatter enabled 三态：false/0/no → 禁用）
//    · create_or_update_skill / delete_skill / toggle_skill
//    · build_skills_list_text（仅启用项；无启用项返回空串）
//
//  W4c 装配：NativeFileSkillsManager 实现 NativeSkillReader（NativeChatRuntime.swift），
//  替换 NativeAgentLoop.routeReadSkill 的「skills_mgr 仍走 HTTP 侧车」占位。
//
//  范围外（W4c 不移植）：
//    · install_skill_from_repo 的 git clone 分支——联网安装通道已由 W3a
//      NativeToolInstall（install_skill 工具）承接；P3-W1b 面板安装端点
//      复用该通道（NativeSidecarClient+Panels.installSkill）。
//

import Foundation

// ════════════════════════════════════════════════════════════
// MARK: - skills_mgr/manager.py 逐行为
// ════════════════════════════════════════════════════════════

public final class NativeSkillsManager: @unchecked Sendable {

    /// 技能根目录（= skills_root()；<data_root>/skills，mkdir 副作用对齐）。
    public let skillsRoot: URL

    /// - Parameter dataRoot: 侧车 VETARAI_DATA_ROOT 等价物；<dataRoot>/skills 自动创建。
    public init(dataRoot: URL) {
        let root = dataRoot.appendingPathComponent("skills", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        self.skillsRoot = root
    }

    /// 测试/特殊装配用：直接指定技能根（mkdir 副作用对齐 skills_root()）。
    public init(skillsRoot: URL) {
        try? FileManager.default.createDirectory(at: skillsRoot, withIntermediateDirectories: true)
        self.skillsRoot = skillsRoot
    }

    // MARK: _valid_skill_name（字母/数字/中文/-/_，1-64 字符）

    /// Python `re.fullmatch(r"[\w\u4e00-\u9fff-]+", name)`：\w = [A-Za-z0-9_] + Unicode 字母数字
    /// （Python \w 默认匹配 Unicode 单词字符；此处按规格正则逐字：ASCII 单词字符 ∪ CJK ∪ '-'，
    ///  另放行其它 Unicode 字母/数字以对齐 Python \w 的 Unicode 语义——如 é。）
    public static func isValidSkillName(_ name: String) -> Bool {
        if name.isEmpty || name.unicodeScalars.count > 64 { return false }
        for ch in name {
            if ch == "-" || ch == "_" { continue }
            if ch.isLetter || ch.isNumber { continue }   // Python \w 的 Unicode 口径（含 CJK）
            return false
        }
        return true
    }

    // MARK: _parse_frontmatter（`---` 简易解析；无/未闭合 frontmatter → ({}, 原文)）

    public static func parseFrontmatter(_ text: String) -> (meta: [String: String], body: String) {
        let text = text
        guard text.hasPrefix("---") else { return ([:], text) }
        let lines = text.components(separatedBy: "\n")
        guard lines.count >= 2 else { return ([:], text) }
        var meta: [String: String] = [:]
        var endIdx: Int? = nil
        for i in 1..<lines.count {
            let stripped = lines[i].trimmingCharacters(in: .whitespaces)
            if stripped == "---" { endIdx = i; break }
            // ^([A-Za-z_][\w-]*)\s*:\s*(.*)$（对 strip 后的行匹配）
            if let m = stripped.range(of: #"^([A-Za-z_][\w-]*)\s*:\s*(.*)$"#,
                                      options: .regularExpression) {
                let match = String(stripped[m])
                guard let colon = match.firstIndex(of: ":") else { continue }
                let key = String(match[..<colon]).trimmingCharacters(in: .whitespaces)
                var val = String(match[match.index(after: colon)...])
                    .trimmingCharacters(in: .whitespaces)
                // .strip('"').strip("'")：去首尾成对的引号字符（Python strip 语义=去两端该字符集）
                val = val.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                meta[key] = val
            }
        }
        guard let end = endIdx else { return ([:], text) }
        let body = lines[(end + 1)...].joined(separator: "\n")
        return (meta, body)
    }

    // MARK: _build_frontmatter

    public static func buildFrontmatter(_ meta: [(String, String)]) -> String {
        var lines = ["---"]
        for (k, v) in meta { lines.append("\(k): \(v)") }
        lines.append("---")
        return lines.joined(separator: "\n")
    }

    // MARK: 文件读写（_skill_dir / _read_skill_file）

    private func skillDir(_ name: String) -> URL {
        skillsRoot.appendingPathComponent(name, isDirectory: true)
    }

    private func readSkillFile(_ name: String) -> String? {
        let f = skillDir(name).appendingPathComponent("SKILL.md")
        guard FileManager.default.fileExists(atPath: f.path) else { return nil }
        return try? String(contentsOf: f, encoding: .utf8)
    }

    /// frontmatter enabled 三态（Python：str(meta.get("enabled","true")).strip().lower()
    /// not in ("false","0","no")）。
    private static func enabledFromMeta(_ meta: [String: String]) -> Bool {
        let raw = (meta["enabled"] ?? "true").trimmingCharacters(in: .whitespaces).lowercased()
        return !["false", "0", "no"].contains(raw)
    }

    // MARK: list_skills（[{name, dir_name, description, enabled, path}]）

    public struct SkillListItem: Sendable, Equatable {
        public var name: String
        public var dirName: String
        public var skillDescription: String
        public var enabled: Bool
        public var path: String
    }

    public func listSkills() -> [SkillListItem] {
        var out: [SkillListItem] = []
        guard let dirs = try? FileManager.default.contentsOfDirectory(
            at: skillsRoot, includingPropertiesForKeys: nil) else { return out }
        for d in dirs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: d.path, isDirectory: &isDir),
                  isDir.boolValue else { continue }
            let dirName = d.lastPathComponent
            guard let text = readSkillFile(dirName) else { continue }
            let (meta, _) = Self.parseFrontmatter(text)
            out.append(SkillListItem(
                name: meta["name"] ?? dirName,
                dirName: dirName,
                skillDescription: meta["description"] ?? "",
                enabled: Self.enabledFromMeta(meta),
                path: d.appendingPathComponent("SKILL.md").path))
        }
        return out
    }

    // MARK: read_skill（{name, dir_name, description, enabled, content}；非法名/不存在 → nil）

    public func readSkill(_ name: String) -> NativeSkillInfo? {
        guard Self.isValidSkillName(name) else { return nil }
        guard let text = readSkillFile(name) else { return nil }
        let (meta, body) = Self.parseFrontmatter(text)
        return NativeSkillInfo(
            dirName: name,
            description: meta["description"] ?? "",
            content: body.trimmingCharacters(in: .whitespacesAndNewlines),
            enabled: Self.enabledFromMeta(meta))
    }

    // MARK: read_skill 面板端点形态（api_read_skill，app.py L2136-2141）

    /// 端点响应同构：name 取 frontmatter name（meta.get("name", name) 回落目录名）。
    /// NativeSkillInfo 无 name 字段（聊天循环注入不需要），面板端点单独开此形态。
    public struct SkillDetailItem: Sendable, Equatable {
        public var name: String
        public var dirName: String
        public var skillDescription: String
        public var enabled: Bool
        public var content: String
    }

    public func readSkillDetail(_ name: String) -> SkillDetailItem? {
        guard Self.isValidSkillName(name) else { return nil }
        guard let text = readSkillFile(name) else { return nil }
        let (meta, body) = Self.parseFrontmatter(text)
        return SkillDetailItem(
            name: meta["name"] ?? name,
            dirName: name,
            skillDescription: meta["description"] ?? "",
            enabled: Self.enabledFromMeta(meta),
            content: body.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: create_or_update_skill

    @discardableResult
    public func createOrUpdateSkill(_ name: String, description: String,
                                    body: String, enabled: Bool = true) -> Bool {
        guard Self.isValidSkillName(name) else { return false }
        do {
            let d = skillDir(name)
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            let desc = description.replacingOccurrences(of: "\n", with: " ")
            let descCut = String(desc.unicodeScalars.prefix(500))
            let fm = Self.buildFrontmatter([
                ("name", name),
                ("description", descCut),
                ("enabled", enabled ? "true" : "false"),
            ])
            try (fm + "\n\n" + body).write(
                to: d.appendingPathComponent("SKILL.md"), atomically: false, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }

    // MARK: delete_skill

    @discardableResult
    public func deleteSkill(_ name: String) -> Bool {
        guard Self.isValidSkillName(name) else { return false }
        let d = skillDir(name)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: d.path, isDirectory: &isDir),
              isDir.boolValue else { return false }
        return (try? FileManager.default.removeItem(at: d)) != nil
    }

    // MARK: toggle_skill（改 frontmatter enabled；返回新状态，失败/不存在 → nil）

    @discardableResult
    public func toggleSkill(_ name: String) -> Bool? {
        guard Self.isValidSkillName(name) else { return nil }
        guard let text = readSkillFile(name) else { return nil }
        var (meta, body) = Self.parseFrontmatter(text)
        let cur = Self.enabledFromMeta(meta)
        meta["enabled"] = cur ? "false" : "true"
        if meta["name"] == nil { meta["name"] = name }   // meta.setdefault("name", name)
        // _build_frontmatter 保 dict 插入序；Python dict 解析序 = 文件行序，此处按
        // (name, description, enabled, 其余键名字典序) 稳定输出——字段集合等价。
        var ordered: [(String, String)] = []
        for k in ["name", "description", "enabled"] {
            if let v = meta[k] { ordered.append((k, v)) }
        }
        for k in meta.keys.sorted() where !["name", "description", "enabled"].contains(k) {
            ordered.append((k, meta[k]!))
        }
        do {
            try (Self.buildFrontmatter(ordered) + "\n\n" + body).write(
                to: skillDir(name).appendingPathComponent("SKILL.md"),
                atomically: false, encoding: .utf8)
            return !cur
        } catch {
            return nil
        }
    }

    // MARK: build_skills_list_text（仅启用项；无启用项 → 空串）

    public func buildSkillsListText() -> String {
        let items = listSkills().filter { $0.enabled }
        if items.isEmpty { return "" }
        return items.map {
            "- \($0.name)：\($0.skillDescription.isEmpty ? "（无描述）" : $0.skillDescription)"
        }.joined(separator: "\n")
    }
}

// ════════════════════════════════════════════════════════════
// MARK: - NativeSkillReader 适配（W4c：routeReadSkill 真实现装配）
// ════════════════════════════════════════════════════════════

extension NativeSkillsManager: NativeSkillReader {
    /// list_skills() 的 dir_name 清单（报错列出可用技能用）。
    public func listSkillNames() -> [String] { listSkills().map { $0.dirName } }
}
