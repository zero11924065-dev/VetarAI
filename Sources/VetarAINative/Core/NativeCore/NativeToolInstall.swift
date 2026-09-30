//
//  NativeToolInstall.swift
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

//  逐行为移植两个只读规格源：
//    · subagent/sidecar/plugin_loader/loader.py install_from_github（L150-228）：
//      出站 guard（_egress：本地路径/allowlist 直连，proxy 挂 -c http.proxy 参数）→
//      本地路径 git clone / GitHub URL 正则取名 → plugins_root/<name>（已存在先删）→
//      manifest.json 缺失写默认（json.dumps indent=2）→ 返回 manifest 信息；
//      git clone timeout=120 + 子进程环境剥离代理变量（_egress_env 唯一漏斗契约）
//    · subagent/sidecar/skills_mgr/manager.py install_skill_from_repo（L190-256）：
//      本地目录直拷（SKILL.md rglob 定位 + frontmatter 取名 + 技能名清洗 +
//      已存在拒绝 + copytree）；远程 git clone --depth 1 到临时目录后同样流程
//
//  执行器抽象（NativeGitRunner）：生产 /usr/bin/env git 子进程（isRunning 轮询 +
//  超时强杀，同 runCode 先例）；测试注入假 runner（本地拷贝造源，不打真网络）。
//
//  微差（汇报清单同步）：
//    ① Python rglob("SKILL.md") 的 cands[0] 依赖 os.scandir 顺序（不定）——
//       本实现按路径码点序取首个（确定性优先，单 SKILL.md 场景无差异）；
//    ② plugin clone 失败的 CalledProcessError 文案按 Python str() 形态复刻
//       （"Command '[...]' returned non-zero exit status N."，argv 走 pyListRepr）。
//

import Foundation

// MARK: - git 执行器

/// git 失败形态（pyDescription 对齐 Python 异常 str()）。
public enum NativeGitError: Error {
    /// subprocess.TimeoutExpired → ValueError("git clone 超时（120s），请检查网络或仓库地址"）。
    case timeout
    /// subprocess.CalledProcessError（check=True）。
    case failed(exitCode: Int32, stderr: String, argv: [String])
    /// 进程无法启动。
    case launchFailed(String)

    public var pyDescription: String {
        switch self {
        case .timeout:
            return "git clone 超时（120s），请检查网络或仓库地址"
        case .failed(let exitCode, _, let argv):
            // str(CalledProcessError)：Command '<argv list repr>' returned non-zero exit status N.
            return "Command '\(WFText.pyListRepr(argv))' returned non-zero exit status \(exitCode)."
        case .launchFailed(let msg):
            return msg
        }
    }
}

/// git clone 执行器（剥离代理环境变量由本层统一处理——guard 唯一漏斗契约）。
public struct NativeGitRunner: Sendable {
    /// （argv 全量含 "git"，env 已剥离代理变量，timeout 秒）→ 成功或失败形态。
    public var run: @Sendable (_ argv: [String], _ timeout: Double) async -> NativeGitError?

    public init(run: @escaping @Sendable ([String], Double) async -> NativeGitError?) {
        self.run = run
    }

    /// _egress_env：子进程环境剥离代理变量（plugin_loader/skills_mgr 同一契约）。
    public static let proxyEnvKeys = ["HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY",
                                      "http_proxy", "https_proxy", "all_proxy"]

    static func egressEnv() -> [String: String] {
        ProcessInfo.processInfo.environment.filter { !proxyEnvKeys.contains($0.key) }
    }

    /// 生产 runner：/usr/bin/env git 子进程；isRunning 轮询 + 超时 terminate→SIGKILL
    /// （与 runCode 同一纪律：绝不 waitUntilExit 防终止事件竞态死等）。
    public static let system = NativeGitRunner { argv, timeout in
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = argv
        proc.environment = egressEnv()
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        // 边跑边攒（防管道缓冲满阻塞子进程）
        final class Buffer: @unchecked Sendable {
            let lock = NSLock(); var data = Data()
            func append(_ d: Data) { lock.lock(); data.append(d); lock.unlock() }
            func read() -> Data { lock.lock(); defer { lock.unlock() }; return data }
        }
        let errBuf = Buffer()
        errPipe.fileHandleForReading.readabilityHandler = { h in errBuf.append(h.availableData) }
        outPipe.fileHandleForReading.readabilityHandler = { h in _ = h.availableData }
        do {
            try proc.run()
        } catch {
            return .launchFailed("\(error.localizedDescription)")
        }
        let deadline = Date().addingTimeInterval(timeout)
        while proc.isRunning {
            if Date() >= deadline {
                proc.terminate()
                let killDeadline = Date().addingTimeInterval(1)
                while proc.isRunning && Date() < killDeadline {
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
                if proc.isRunning {
                    kill(proc.processIdentifier, SIGKILL)
                    let reapDeadline = Date().addingTimeInterval(1)
                    while proc.isRunning && Date() < reapDeadline {
                        try? await Task.sleep(nanoseconds: 50_000_000)
                    }
                }
                return .timeout
            }
            if Task.isCancelled { proc.terminate(); return .timeout }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        errPipe.fileHandleForReading.readabilityHandler = nil
        outPipe.fileHandleForReading.readabilityHandler = nil
        guard proc.terminationStatus == 0 else {
            let stderr = String(decoding: errBuf.read(), as: UTF8.self)
            return .failed(exitCode: proc.terminationStatus, stderr: stderr, argv: argv)
        }
        return nil
    }
}

// MARK: - 安装实现

public enum NativeToolInstall {

    /// clone 超时（M3 前置安全加固 L3；plugin_loader/skills_mgr 同为 120s）。
    public static let gitCloneTimeout = 120.0

    // MARK: install_plugin（PluginLoader.install_from_github 移植）

    /// 返回 Python info dict 同构（name/version/path/entry_point/hooks/description）。
    public static func installPlugin(_ repoUrl: String,
                                     context: NativeToolContext) async throws -> [String: JSONValue] {
        // P1-4：出站必须过 guard（本地路径/allowlist 直连，走代理挂配置代理，熔断秒拒）
        let gitProxyArgs = try egressArgs(repoUrl, context: context)
        var egressHost = ""
        if !repoUrl.hasPrefix("/") {
            egressHost = parseHost(repoUrl)
        }

        let pluginsRoot = try context.pluginsRoot()
        let fm = FileManager.default
        let name: String
        let pluginDir: URL

        if repoUrl.hasPrefix("/") {
            // 本地 git 仓库
            var trimmed = repoUrl
            while trimmed.hasSuffix("/") { trimmed.removeLast() }   // rstrip("/")
            name = NativePyPath.name(trimmed)
            pluginDir = pluginsRoot.appendingPathComponent(name)
            if fm.fileExists(atPath: pluginDir.path) {
                try fm.removeItem(at: pluginDir)
            }
            try fm.createDirectory(at: pluginDir, withIntermediateDirectories: true)
            if let failure = await context.gitRunner.run(
                ["git", "clone"] + gitProxyArgs + [repoUrl, pluginDir.path], gitCloneTimeout) {
                throw failure
            }
        } else {
            guard let match = repoUrlRegex(#"/([^/]+)/([^/.]+?)(?:\.git)?$"#, in: repoUrl) else {
                throw NativeToolValueError(message: "Invalid GitHub URL: \(repoUrl)")
            }
            name = match
            pluginDir = pluginsRoot.appendingPathComponent(name)
            if fm.fileExists(atPath: pluginDir.path) {
                try fm.removeItem(at: pluginDir)
            }
            try fm.createDirectory(at: pluginDir, withIntermediateDirectories: true)
            if let failure = await context.gitRunner.run(
                ["git", "clone"] + gitProxyArgs + [repoUrl, pluginDir.path], gitCloneTimeout) {
                // 2026-08-28 融合方案：失败计入熔断（防无代理空转）
                if !egressHost.isEmpty {
                    context.networkGuard.reportFailure(egressHost)
                }
                throw failure
            }
            if !egressHost.isEmpty {
                context.networkGuard.reportSuccess(egressHost)
            }
        }

        let manifestPath = pluginDir.appendingPathComponent("manifest.json")
        let manifest: [String: JSONValue]
        if !fm.fileExists(atPath: manifestPath.path) {
            // json.dumps(manifest, indent=2)——键序保 Python dict 插入序（字节级可比）
            let nameJSON = NativeDatabase.dumpsUTF8(.string(name))
            let text = """
                {
                  "name": \(nameJSON),
                  "version": "0.1.0",
                  "entry_point": "plugin.py",
                  "api_version": "1.0",
                  "hooks": [
                    "on_message"
                  ],
                  "dependencies": []
                }
                """
            try text.write(to: manifestPath, atomically: false, encoding: .utf8)
            manifest = [
                "name": .string(name),
                "version": .string("0.1.0"),
                "entry_point": .string("plugin.py"),
                "api_version": .string("1.0"),
                "hooks": .array([.string("on_message")]),
                "dependencies": .array([]),
            ]
        } else {
            let text = try String(contentsOf: manifestPath, encoding: .utf8)
            // json.loads 失败 → Python 抛 JSONDecodeError（registry 归 install_failed）；
            // 原生侧如实报错（行列号格式不逐字复刻）
            guard let parsed = NativeJSONWriter.loadsFragment(Data(text.utf8))?.object else {
                throw NativeToolValueError(message: "manifest.json 不是合法 JSON（解析失败）")
            }
            manifest = parsed
        }

        return [
            "name": manifest["name"] ?? .string(name),
            "version": manifest["version"] ?? .string("0.1.0"),
            "path": .string(pluginDir.path),
            "entry_point": manifest["entry_point"] ?? .string("plugin.py"),
            "hooks": manifest["hooks"] ?? .array([]),
            "description": manifest["description"] ?? .string(""),
        ]
    }

    /// PluginLoader._egress：对插件仓库域名做出站 guard，返回 git 代理参数。
    /// 本地路径/本地 host → []；allowlist 命中 → []（直连）；被拒 → 抛 NetworkGuardError。
    static func egressArgs(_ repoUrl: String, context: NativeToolContext) throws -> [String] {
        let host = repoUrl.hasPrefix("/") ? "" : parseHost(repoUrl)
        if host.isEmpty { return [] }   // 本地路径，无需 guard
        let proxies = try context.networkGuard.assertGuard(host)
        guard let proxies, let base = proxies["http"] else { return [] }   // 本地/allowlist → 直连
        return ["-c", "http.proxy=\(base)", "-c", "https.proxy=\(base)"]
    }

    /// urlparse(url if "://" in url else "https://"+url).hostname or ""（loader.py L130-133）。
    static func parseHost(_ repoUrl: String) -> String {
        let withScheme = repoUrl.contains("://") ? repoUrl : "https://\(repoUrl)"
        return URL(string: withScheme)?.host ?? ""
    }

    /// 仓库名正则取第二捕获组（/owner/repo(.git)?$ → repo）。
    static func repoUrlRegex(_ pattern: String, in text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        guard let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges > 2 else { return nil }
        return ns.substring(with: m.range(at: 2))
    }

    // MARK: install_skill（install_skill_from_repo 移植）

    /// 返回 Python res dict 同构：{"ok": bool, "name"? | "error"?}。
    public static func installSkillFromRepo(_ urlOrPath: String,
                                            context: NativeToolContext) async throws -> [String: JSONValue] {
        let src = urlOrPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !src.isEmpty else {
            return ["ok": .bool(false), "error": .string("地址不能为空")]
        }
        let fm = FileManager.default
        let local = NativePyPath.expanduser(src)
        if fm.fileExists(atPath: local) {
            // 本地路径直接复制
            var skillMD = (local as NSString).appendingPathComponent("SKILL.md")
            var isFile = ObjCBool(false)
            if !(fm.fileExists(atPath: skillMD, isDirectory: &isFile) && !isFile.boolValue) {
                let cands = rglobSKILLmd(local)
                guard let first = cands.first else {
                    return ["ok": .bool(false), "error": .string("该目录内未找到 SKILL.md")]
                }
                skillMD = first
            }
            return copySkillDir(skillMDPath: skillMD, context: context)
        }

        // 远程：git clone --depth 1 到临时目录（克隆过 guard 契约：剥离代理环境变量 + 120s）
        let tmp = fm.temporaryDirectory
            .appendingPathComponent("skill_install_\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }
        if let failure = await context.gitRunner.run(
            ["git", "clone", "--depth", "1", src, tmp.path], gitCloneTimeout) {
            switch failure {
            case .timeout:
                return ["ok": .bool(false), "error": .string("git clone 超时（120s）")]
            case .failed(_, let stderr, _):
                let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                return ["ok": .bool(false),
                        "error": .string("git clone 失败：\(WFText.pyPrefix(trimmed, 200))")]
            case .launchFailed(let msg):
                return ["ok": .bool(false), "error": .string("安装失败：\(msg)")]
            }
        }
        let cands = rglobSKILLmd(tmp.path)
        guard let skillMD = cands.first else {
            return ["ok": .bool(false), "error": .string("仓库内未找到 SKILL.md")]
        }
        return copySkillDir(skillMDPath: skillMD, context: context)
    }

    /// 本地/克隆后共用：frontmatter 取名 → 技能名清洗 → 已存在拒绝 → copytree。
    static func copySkillDir(skillMDPath: String,
                             context: NativeToolContext) -> [String: JSONValue] {
        let fm = FileManager.default
        let parentDir = (skillMDPath as NSString).deletingLastPathComponent
        do {
            let text = try String(contentsOfFile: skillMDPath, encoding: .utf8)
            let (meta, _) = parseFrontmatter(text)
            var name = meta["name"] ?? ""
            if name.isEmpty { name = NativePyPath.name(parentDir) }
            guard validSkillName(name) else {
                return ["ok": .bool(false), "error": .string("技能名非法: \(name)")]
            }
            let dest = try context.skillsRoot().appendingPathComponent(name)
            if fm.fileExists(atPath: dest.path) {
                return ["ok": .bool(false), "error": .string("技能已存在: \(name)")]
            }
            try fm.copyItem(atPath: parentDir, toPath: dest.path)
            return ["ok": .bool(true), "name": .string(name)]
        } catch {
            // 兜底（Python except Exception → "安装失败：{e}"）
            return ["ok": .bool(false), "error": .string("安装失败：\(error.localizedDescription)")]
        }
    }

    /// rglob("SKILL.md")（按路径码点序——见文件头微差①）。
    static func rglobSKILLmd(_ root: String) -> [String] {
        let fm = FileManager.default
        guard let en = fm.enumerator(atPath: root) else { return [] }
        var out: [String] = []
        for case let rel as String in en {
            if NativePyPath.name(rel) == "SKILL.md" {
                out.append((root as NSString).appendingPathComponent(rel))
            }
        }
        return out.sorted { $0.unicodeScalars.lexicographicallyPrecedes($1.unicodeScalars) }
    }

    /// _valid_skill_name：字母/数字/中文/-/_，1-64 字符（[\w一-龥-]+ fullmatch；
    /// len 按码点计，对齐 Python len(str)）。
    public static func validSkillName(_ name: String) -> Bool {
        guard !name.isEmpty, name.unicodeScalars.count <= 64 else { return false }
        return name.unicodeScalars.allSatisfy { sc in
            sc == "_" || sc == "-"
                || (sc.value >= 0x4E00 && sc.value <= 0x9FFF)
                || CharacterSet.alphanumerics.contains(sc)
        }
    }

    /// _parse_frontmatter：解析 `---` frontmatter，返回 (meta, body)。无 → ([:], 原文)。
    public static func parseFrontmatter(_ text: String) -> (meta: [String: String], body: String) {
        guard text.hasPrefix("---") else { return ([:], text) }
        let lines = text.components(separatedBy: "\n")
        guard lines.count >= 2 else { return ([:], text) }
        var meta: [String: String] = [:]
        var endIdx: Int? = nil
        let keyRe = try? NSRegularExpression(pattern: #"^([A-Za-z_][\w-]*)\s*:\s*(.*)$"#)
        for i in 1..<lines.count {
            // Python lines[i].strip()（含 \r，CRLF 文件兼容）
            let stripped = lines[i].trimmingCharacters(in: .whitespacesAndNewlines)
            if stripped == "---" {
                endIdx = i
                break
            }
            let ns = stripped as NSString
            if let m = keyRe?.firstMatch(in: stripped, range: NSRange(location: 0, length: ns.length)) {
                let key = ns.substring(with: m.range(at: 1))
                // Python m.group(2).strip().strip('"').strip("'")：
                // strip(chars) 双侧独立去除该字符集的全部前导/尾随字符
                let value = ns.substring(with: m.range(at: 2))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                    .trimmingCharacters(in: CharacterSet(charactersIn: "'"))
                meta[key] = value
            }
        }
        guard let endIdx else { return ([:], text) }
        let body = lines[(endIdx + 1)...].joined(separator: "\n")
        return (meta, body)
    }
}
