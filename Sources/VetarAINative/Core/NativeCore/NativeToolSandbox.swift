//
//  NativeToolSandbox.swift
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

//  逐行为移植 subagent/sidecar/tools/registry.py 的路径解析段（L53-123）与
//  subagent/sidecar/tools/sandbox.py（⛔ 只读行为规格源，74 行）：
//    · resolve_sandboxed_path：expanduser → resolve（符号链接跟随），含
//      双前缀自纠正（checkpoint-069 F-1：首层==根目录名且去首层后存在 → 去首层）
//    · punctuation_near_miss（0.4.11 第六十四章）：目标与沙盒根【仅差标点】→
//      返回正确路径建议；已存在的同名异标点目录绝不干预
//    · is_sensitive_path：敏感系统位置判定（/System /etc /usr … + ~/.ssh 等
//      用户关键资产 + ~/.subagent 应用自身数据）；解析异常按敏感处理（保守）
//
//  Python Path.resolve() ↔ NSString 三段式映射（expanduser → standardize →
//  resolveSymlinks）：相对路径先锚定 cwd（Path.resolve 语义）；macOS /var→/private/var
//  符号链接由 resolvingSymlinksInPath 覆盖（mktemp 路径比对的前置条件）。
//

import Foundation

// MARK: - Python Path 语义路径助手

enum NativePyPath {

    /// Path(p).expanduser().resolve() 近似：~ 展开 → 锚定 cwd（相对路径）→
    /// 标准化（. / .. / 重复斜杠）→ 符号链接解析。路径不存在仍返回解析结果。
    static func resolve(_ p: String) -> String {
        var s = (p as NSString).expandingTildeInPath
        if !(s as NSString).isAbsolutePath {
            s = (FileManager.default.currentDirectoryPath as NSString).appendingPathComponent(s)
        }
        s = (s as NSString).standardizingPath
        s = (s as NSString).resolvingSymlinksInPath
        return s
    }

    /// Path(p).expanduser()（不 resolve）。
    static func expanduser(_ p: String) -> String {
        (p as NSString).expandingTildeInPath
    }

    static func isAbsolute(_ p: String) -> Bool { (p as NSString).isAbsolutePath }

    /// Path.name（末段；去尾斜杠后取；"/" → ""）。
    static func name(_ p: String) -> String {
        var s = p
        while s.count > 1 && s.hasSuffix("/") { s.removeLast() }
        if s == "/" { return "" }
        return (s as NSString).lastPathComponent
    }

    /// Path.parts（相对/绝对路径逐段；折叠重复斜杠与 "."，保留 ".."）。
    static func parts(_ p: String) -> [String] {
        p.split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { $0 != "." }
    }

    /// list(target.parents)：自直接父目录逐级向上至 "/"。
    static func parents(_ p: String) -> [String] {
        var out: [String] = []
        var cur = p
        while cur != "/" {
            let parent = (cur as NSString).deletingLastPathComponent
            out.append(parent.isEmpty ? "/" : parent)
            cur = parent.isEmpty ? "/" : parent
        }
        return out
    }

    /// target 是否 == root 或位于其下（Path.relative_to 判定语义，逐段比较非字符串前缀）。
    static func isWithin(_ target: String, root: String) -> Bool {
        target == root || target.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    /// target 去掉 root 前缀后的逐段相对路径（relative_to；调用方保证 isWithin）。
    static func relativeParts(_ target: String, to root: String) -> [String] {
        if target == root { return [] }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        guard target.hasPrefix(prefix) else { return [] }
        return parts(String(target.dropFirst(prefix.count)))
    }

    static func join(_ base: String, _ parts: [String]) -> String {
        parts.reduce(base) { ($0 as NSString).appendingPathComponent($1) }
    }

    static func exists(_ p: String) -> Bool { FileManager.default.fileExists(atPath: p) }
}

// MARK: - 沙盒路径解析（registry.py L53-79 移植）

public enum NativeToolSandbox {

    /// resolve_sandboxed_path：相对/绝对路径 → 沙盒根下绝对路径（含双前缀自纠正）。
    /// 返回 nil = Python 返回 None（rel 非串/空）。路径不存在仍返回解析结果。
    public static func resolveSandboxedPath(_ rel: String?, sandboxRoot: String) -> String? {
        let root = NativePyPath.resolve(sandboxRoot)
        guard let rel, !rel.isEmpty else { return nil }
        let expanded = NativePyPath.expanduser(rel)
        let candidate = NativePyPath.isAbsolute(expanded) ? expanded
            : (root as NSString).appendingPathComponent(expanded)
        var resolved = NativePyPath.resolve(candidate)
        // 双前缀自纠正（checkpoint-069 F-1）：模型把沙盒根目录名当相对前缀再叠一层
        // （root=~/Desktop/测试材料 时传 "测试材料/测试存档/..."）→ 去首层重试。
        if !NativePyPath.exists(resolved) && !NativePyPath.isAbsolute(rel) {
            let relParts = NativePyPath.parts(rel)
            if let first = relParts.first, first == NativePyPath.name(root) {
                let alt = relParts.count > 1 ? NativePyPath.join(root, Array(relParts.dropFirst())) : root
                if NativePyPath.exists(alt) {
                    resolved = NativePyPath.resolve(alt)
                }
            }
        }
        return resolved
    }

    // MARK: - 0.4.11 路径标点笔误自检（registry.py L88-123）

    /// _PUNCT_CHARS：中英文常见句读与引号括号（模型笔误高发字符；含空格/全角空格/Tab）。
    public static let punctChars: Set<Character> = [
        "。", "，", "、", "；", "：", "！", "？", ".", ",", ";", ":", "!", "?",
        "·", "…", "—", "-", "–", "~", "～",
        "\"", "'", "“", "”", "‘", "’",
        "（", "）", "(", ")", "【", "】", "[", "]", "{", "}", "<", ">", "《", "》",
        " ", "　", "\t",
    ]

    /// _strip_punct。
    public static func stripPunct(_ s: String) -> String {
        String(s.filter { !punctChars.contains($0) })
    }

    /// punctuation_near_miss：目标路径与沙盒根【仅差标点】→ 返回正确路径建议，否则 nil。
    /// 只在"那个带标点的祖先目录不存在"时命中；已存在目录绝不干预（不得把用户引开）。
    public static func punctuationNearMiss(resolved: String, sandboxRoot: String) -> String? {
        let rp = NativePyPath.resolve(sandboxRoot)
        let rootKey = stripPunct(NativePyPath.name(rp))
        guard !rootKey.isEmpty else { return nil }
        let target = resolved
        for anc in NativePyPath.parents(target) + [target] {
            if anc == rp || NativePyPath.exists(anc) { continue }   // 已存在的目录不干预
            let ancName = NativePyPath.name(anc)
            if ancName != NativePyPath.name(rp) && stripPunct(ancName) == rootKey {
                return NativePyPath.join(rp, NativePyPath.relativeParts(target, to: anc))
            }
        }
        return nil
    }

    // MARK: - 敏感路径判定（sandbox.py L33-74 移植）

    /// _SENSITIVE_DIRS（系统级；注意不含 /private/var——macOS 临时目录全解析到该前缀）。
    public static let sensitiveDirs = [
        "/System", "/etc", "/private/etc", "/usr", "/bin", "/sbin",
        "/Applications", "/Library", "/boot", "/dev",
    ]

    /// _sensitive_home_entries（延迟求值跟随真实 home；含 ~/.subagent 应用自身数据）。
    public static func sensitiveHomeEntries(home: String = NSHomeDirectory()) -> [String] {
        [
            home + "/.ssh", home + "/.gnupg", home + "/.aws",
            home + "/.netrc", home + "/.zshrc", home + "/.zprofile",
            home + "/.bashrc", home + "/.bash_profile",
            home + "/Library/Keychains",
            home + "/.subagent",
        ]
    }

    /// is_sensitive_path：命中敏感目录（含子路径）或等于/位于敏感主目录条目之下。
    public static func isSensitivePath(_ target: String, home: String = NSHomeDirectory()) -> Bool {
        let s = NativePyPath.resolve(target)
        for d in sensitiveDirs where s == d || s.hasPrefix(d + "/") { return true }
        for e in sensitiveHomeEntries(home: home) where s == e || s.hasPrefix(e + "/") { return true }
        return false
    }
}
