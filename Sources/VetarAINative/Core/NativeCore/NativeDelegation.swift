//
//  NativeDelegation.swift
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

//  逐行为移植 subagent/sidecar/agent_engine/delegation.py（984 行，⛔ 只读行为
//  规格源；语义分歧以 Python 源码为准）+ loop.py 的 delegate_task 路由段
//  （L1822-2017：F1 附件拦截 / REQ-AGT-019 零图守卫 / 目标解析 / 自动新建 /
//  模型换装编排）与 loop.py 的附件装载段（L837-1045：_load_delegation_images /
//  _resolve_delegation_files / _real_images_hint / _real_docs_hint / _IMAGE_INTENT_RE）。
//
//  委派执行器内核：
//    · 交卷契约（决策 3）：parse_report 宽容归一化（task_id/status 小错修正接收；
//      仅"完全不是 JSON 交卷"判 None）+ #7 JSON 块外正文并入 summary（≥20 字阈值、
//      防重复并入、不破坏 markdown 表格/粗斜体/破折号）+ H17 兜底打包
//    · 简单委派模式（TS-118）：带图强制 / 显式传参 / OCR 专用模型 → 不拼契约、
//      任务书从简、第一轮原文直接作为结果（不校验不追问）
//    · 目标解析（决策 8）：精确 → 模糊（互为子串，多命中取 name 最短）→ 列可用名单
//    · 自动新建子 Agent（决策 9/10）：重名追加 -2/-3…；开关关闭转述用户
//    · 串行锁（决策 4）：同一时刻只有一个子任务在推理；task_concurrency 开关放开
//    · 取消（TS-114）：检查点 1-4 + loop 每轮 cancelCheck；任务标 failed（含"已停止"）
//    · 活性超时（checkpoint-068 D-7）：delegation_activity_timeout 秒，0=关
//    · 前置守卫（D-8）：相同任务书去重 + 失败重试上限（delegation_max_retries）
//    · 排队语义（TS-108）：先落库 queued → 等锁 → running
//    · 附件通道：image_paths 后端代读为 data URI 注入视觉流；file_paths 只解析
//      路径写进任务书【必读文件】段，由子 Agent 自己 read_file（主 Agent 不代读）
//    · 进度转发（#15）：token 节流为 ≥2s 一次 progress；tool_call/tool_result/
//      state 逐条转发；全部包安全网——总线是旁路，失败绝不影响委派
//    · 子会话双保险禁再委派：toolsSpec(withDelegation:false, withInstall:false)
//      + 路由层 delegationCtx 为 nil 即拒（NativeAgentLoop.routeDelegate）
//
//  偏差（汇报清单同步）：
//    ① connector 能力缝：Python 直接用 connector 调 list_models//api/show/unload；
//       Swift 注入闭包（listModels/visionProbe/safeUnloadModel），nil 即走 Python
//       异常降级路径（跳过校验 / 视为支持视觉 / 卸载无操作）——生产装配由 W4c 接线。
//    ② REQ-AGT-020：app_events A13 资源总线 P2-W4d 已原生落地（NativeAppEvents）。
//       四处写子会话点默认硬连线真总线（notifyChildSessionChanged 对齐
//       delegation.py _notify_child_session_changed），childSessionNotifier
//       通知钩保留为测试/装配附加缝（叠加触发，不替代总线）。
//    ③ 交卷全文落盘默认实现复刻 exporter.save_delegation_report_md（导出目录
//       解析三级回退：config default_export_dir → 项目工作目录 → <data_root>/exports），
//       可用 reportSaver 闭包整体替换。
//    ④ Python asyncio.Lock 串行 → NativeDelegationGate actor（FIFO；等待中被取消
//       经 withTaskCancellationHandler 摘除并放行，调用方 isCancelled 自查兜底——
//       对齐 DBG-140 先例）。asyncio.wait_for 活性超时 → 双任务竞速 TaskGroup。
//    ⑤ 知识/记忆/技能注入（TS-110 M4）以 provider 闭包注入，nil = 降级为空文本
//       （Python try/except 降级路径），不阻塞委派。
//

import Foundation

// ════════════════════════════════════════════════════════════
// MARK: - 交卷契约常量与纯函数（delegation.py L47-602）
// ════════════════════════════════════════════════════════════

public enum NativeDelegation {

    // ── 交卷契约常量（决策 3；M7 TS-113 扩容 300→1000）──
    public static let reportStatuses: Set<String> = ["success", "partial", "failed"]
    public static let summaryMaxLen = 1000
    public static let artifactsMaxItems = 20
    /// _OUTSIDE_BODY_MIN_LEN：JSON 交卷块【外】正文的最小保留长度（低于此视为噪声不并入）。
    public static let outsideBodyMinLen = 20
    /// DEFAULT_ACTIVITY_TIMEOUT（D-7；配置 delegation_activity_timeout 覆盖，0=关）。
    public static let defaultActivityTimeout = 900.0

    /// _RETRY_PROMPT_TMPL（决策 3：校验失败后追问 1 次固定文案）。
    public static func retryPrompt(taskId: String) -> String {
        "你的交卷未通过格式校验。请重新交卷：只输出一个 JSON 对象，字段为 "
            + "{\"task_id\": \"\(taskId)\", \"status\": \"success/partial/failed\", "
            + "\"summary\": \"≤1000字摘要\", \"artifacts\": [ ... ]}。不要输出 JSON 以外的任何文字。"
    }

    /// _REPORT_CONTRACT_PROMPT（子 Agent system prompt 尾部追加的交卷契约说明）。
    public static let reportContractPrompt = (
        "\n【交卷契约】\n"
        + "你正在执行一个委派任务。完成工作后，最终回复必须是且仅是以下 JSON（不要加任何解释文字）：\n"
        + "{\"task_id\": \"<任务ID>\", \"status\": \"success 或 partial 或 failed\", "
        + "\"summary\": \"<不超过1000字的工作摘要>\", \"artifacts\": [\"<产出文件路径或结果说明，可多条，没有则空数组>\"]}\n"
        + "task_id 必须填写任务书中给出的任务ID。"
    )

    /// Python len(str)：码点计数。
    static func pyLen(_ s: String) -> Int { s.unicodeScalars.count }

    static func pyPrefix(_ s: String, _ n: Int) -> String { String(s.unicodeScalars.prefix(n)) }

    static func pyTrim(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Python f"{list_of_str}"：['a', 'b'] 形态（单引号）。
    static func pyListRepr(_ items: [String]) -> String {
        "[" + items.map { "'\($0)'" }.joined(separator: ", ") + "]"
    }

    // MARK: _norm_task_text（D-8 去重比对归一化）

    /// 归一化任务书文本：去首尾空白、压缩连续空白、去首尾标点（。．. 空格 Tab）。
    public static func normTaskText(_ t: String) -> String {
        let s = t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return s.trimmingCharacters(in: CharacterSet(charactersIn: "。．. \t"))
    }

    // MARK: 简单委派模式（TS-118，0.1.71）

    /// is_simple_delegation_model：OCR 专用小模型（名称含 ocr）只输出识别文字。
    public static func isSimpleDelegationModel(_ model: String) -> Bool {
        model.lowercased().contains("ocr")
    }

    /// resolve_simple_mode：带图 → 强制启用；其余看显式参数或目标模型类型。
    public static func resolveSimpleMode(images: [String]?, model: String,
                                         simpleMode: Bool? = nil) -> Bool {
        if let images, !images.isEmpty { return true }
        if simpleMode == true { return true }
        return isSimpleDelegationModel(model)
    }

    // MARK: 目标模型视觉能力检测（TS-118）

    /// _MULTIMODAL_NAME_PATTERNS：已知多模态家族名。
    public static let multimodalNamePatterns = [
        "qwen-vl", "qwen2-vl", "qwen2.5-vl", "qwen3-vl", "qwen3.5-vl",
        "llava", "minicpm-v", "glm-4v", "glm-ocr", "moondream", "bakllava",
        "gemma3", "llama3.2-vision", "mllama", "llama4", "granite-vision",
        "aya-vision", "qwen2.5-omni", "omni",
    ]

    /// model_name_suggests_vision：已知多模态家族 → true；无法判断 → nil
    /// （由调用方继续查模型元数据）。纯名称层不判 false，避免误杀自定义标签模型。
    public static func modelNameSuggestsVision(_ model: String) -> Bool? {
        let ml = model.lowercased()
        for p in multimodalNamePatterns where ml.contains(p) { return true }
        return nil
    }

    // MARK: 交卷解析与校验（决策 3 + #7 块外正文并入）

    /// _extract_json_candidate：首个 { 到最后一个 } 的子串；兼容 ```json 围栏。
    public static func extractJsonCandidate(_ text: String) -> String? {
        guard !text.isEmpty else { return nil }
        let t = pyTrim(text)
        if t.contains("```") {
            for seg in t.components(separatedBy: "```") {
                var s = pyTrim(seg)
                if s.hasPrefix("json") { s = pyTrim(String(s.dropFirst(4))) }
                if s.hasPrefix("{") && s.hasSuffix("}") { return s }
            }
        }
        guard let start = t.firstIndex(of: "{"), let end = t.lastIndex(of: "}"),
              end > start else { return nil }
        return String(t[start...end])
    }

    /// _extract_outside_body：JSON 交卷块【之外】的实质正文。
    /// 块以换行替换（防前后文字粘连）；只剥离【独占整行】的围栏与分隔线
    /// （⛔ 绝不全局 replace——表格 |---|---|、粗斜体 ***重要***、2024---2025 会被破坏）。
    public static func extractOutsideBody(_ text: String, candidate: String?) -> String {
        guard !text.isEmpty else { return "" }
        let t = pyTrim(text)
        var outside = t
        if let candidate, !candidate.isEmpty, let range = t.range(of: candidate) {
            outside = t.replacingCharacters(in: range, with: "\n")
        }
        var kept: [String] = []
        for line in outside.components(separatedBy: "\n") {
            let s = pyTrim(line)
            if s == "```" || s == "```json" || s == "```JSON" { continue }
            if s.count >= 3,
               s.allSatisfy({ $0 == "-" }) || s.allSatisfy({ $0 == "*" })
                || s.allSatisfy({ $0 == "=" }) { continue }
            kept.append(line)
        }
        return pyTrim(kept.joined(separator: "\n"))
    }

    /// Python str(x)：JSONValue → 文本（summary/artifacts 元素强转用）。
    static func pyStr(_ v: JSONValue) -> String {
        switch v {
        case .string(let s): return s
        case .int(let i): return String(i)
        case .double(let d): return NativeJSONWriter.pyFloatRepr(d)
        case .bool(let b): return b ? "True" : "False"
        case .null: return "None"
        case .array, .object: return NativeDatabase.dumpsUTF8(v)
        }
    }

    /// parse_report：解析并校验子 Agent 交卷。合法返回归一化 report dict，否则 nil。
    /// 宽容归一化（H17）：交卷结构存在即接收，小错自动修正（format_corrected 标注）。
    public static func parseReport(_ text: String, taskId: String) -> [String: JSONValue]? {
        guard let candidate = extractJsonCandidate(text),
              let data = candidate.data(using: .utf8),
              let obj = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .object(let dict) = obj else { return nil }
        var corrected = false
        // status 非法 → 归一 partial
        var status = dict["status"]?.string ?? ""
        if !reportStatuses.contains(status) {
            status = "partial"
            corrected = true
        }
        // summary 缺失 → 无交卷结构可言
        guard let summaryRaw = dict["summary"] else { return nil }
        var summary = pyStr(summaryRaw)
        if pyLen(summary) > summaryMaxLen {
            // M7（TS-113）：不在此截断——全文由 finalizeSummary 落盘后再截断回传
            corrected = true
        }
        if pyTrim(dict["task_id"].map { pyStr($0) } ?? "") != taskId {
            corrected = true
        }
        var artifacts: [JSONValue] = []
        if let raw = dict["artifacts"], raw != .null {
            if case .array(let arr) = raw {
                artifacts = arr.prefix(artifactsMaxItems).map { .string(pyStr($0)) }
            } else {
                corrected = true
            }
        }
        // #7（0.4.19）核心修复：JSON 块【外】的实质正文并入 summary
        // （主 Agent 只读 summary；并入后 >1000 字由 finalizeSummary 落盘+回传路径）。
        let outside = extractOutsideBody(text, candidate: candidate)
        if pyLen(outside) >= outsideBodyMinLen && !summary.contains(outside) {
            if pyTrim(summary).isEmpty {
                summary = outside
            } else {
                // Python summary.rstrip()：只去尾部空白后拼接
                var s = summary
                while let last = s.unicodeScalars.last,
                      CharacterSet.whitespacesAndNewlines.contains(last) {
                    s.unicodeScalars.removeLast()
                }
                summary = s + "\n\n" + outside
            }
        }
        var report: [String: JSONValue] = [
            "task_id": .string(taskId), "status": .string(status),
            "summary": .string(summary), "artifacts": .array(artifacts),
        ]
        if corrected { report["format_corrected"] = .bool(true) }
        return report
    }

    /// build_fallback_report（H17 问题4）：弱模型两次交卷均无 JSON → 实质回复打包为
    /// partial 交卷（成果不丢、不逼主 Agent 自己重做）。空/<10 字 → nil。
    public static func buildFallbackReport(_ text: String, taskId: String) -> [String: JSONValue]? {
        let body = pyTrim(text)
        if body.isEmpty || pyLen(body) < 10 { return nil }
        return [
            "task_id": .string(taskId), "status": .string("partial"),
            "summary": .string("（子 Agent 未按契约交卷，以下为其实质回复）" + body),
            "artifacts": .array([]), "fallback": .bool(true),
        ]
    }

    /// _build_simple_report（TS-118）：简单模式第一轮原文直接打包（不校验、不追问）。
    public static func buildSimpleReport(_ fullText: String, taskId: String) -> [String: JSONValue]? {
        let body = pyTrim(fullText)
        if body.isEmpty { return nil }
        return [
            "task_id": .string(taskId), "status": .string("success"),
            "summary": .string(body), "artifacts": .array([]), "simple": .bool(true),
        ]
    }

    // MARK: 任务书模板（_task_user_message / _task_user_message_simple）

    /// 普通模式任务消息：任务书 + 附图提示 + 必读文件清单 + 执行须知 + 防幻觉硬约束。
    public static func taskUserMessage(taskId: String, task: String, expect: String,
                                       imageCount: Int = 0, filePaths: [String]? = nil) -> String {
        let imgHint = imageCount > 0
            ? "附图 \(imageCount) 张已随任务书发送，请直接识别，无需 read_file。\n\n" : ""
        var fileHint = ""
        if let filePaths, !filePaths.isEmpty {
            let lines = filePaths.map { "  - \($0)" }.joined(separator: "\n")
            fileHint = (
                "【必读文件】（路径已由系统校验存在，请逐个用 read_file 读取；"
                + "docx/xlsx/pptx/pdf 会自动解析为文本+格式概要）：\n"
                + "\(lines)\n"
                + "⛔ 任务依赖这些文件的内容，必须先 read_file 读到真实内容再处理，"
                + "禁止凭文件名臆测内容；读不到或解析失败要如实交卷 status=failed 并说明。\n\n"
            )
        }
        return (
            "【委派任务】\n"
            + "任务ID：\(taskId)\n"
            + "任务目标与输入：\n"
            + "\(task)\n\n"
            + "交卷标准：\n"
            + "\(expect)\n\n"
            + "\(imgHint)"
            + "\(fileHint)"
            + "【执行须知】读取文件前必须先用 list_dir 列出目录确认文件真实存在，"
            + "禁止凭猜测的文件名直接 read_file；找不到文件就如实说明，不要编造。\n"
            + "【防幻觉硬约束】\n"
            + "1. 转写/识别图片时，必须逐字如实记录图片中真实可见的文字；严禁编造图片中不存在的"
            + "内容、对话、时间戳或数据。宁可少报，不可编造。\n"
            + "2. 严禁伪造执行记录：不得编造“已读取/已保存/准确率xx%”等未经工具真实验证的描述；"
            + "凡声称保存了文件，必须真实调用 write_file 且工具返回 ok。\n"
            + "3. 图片读不到、看不清或无法转写时，必须如实交卷 status=failed 并说明原因，"
            + "绝不允许输出编造内容。\n"
            + "完成后请按【交卷契约】输出交卷内容。"
        )
    }

    /// 简单模式任务消息（TS-118）：只留任务书本身 + 最小交付要求。
    public static func taskUserMessageSimple(taskId: String, task: String, expect: String,
                                             imageCount: Int = 0, filePaths: [String]? = nil) -> String {
        let imgHint = imageCount > 0
            ? "附图 \(imageCount) 张已随任务书发送，请直接识别，无需 read_file。\n\n" : ""
        // #15（0.4.19）：简单模式也支持必读文件，措辞从简（小模型注意力有限）。
        var fileHint = ""
        if let filePaths, !filePaths.isEmpty {
            let lines = filePaths.map { "  - \($0)" }.joined(separator: "\n")
            fileHint = "【必读文件】请先用 read_file 读取以下文件再处理：\n\(lines)\n\n"
        }
        return (
            "【委派任务】\n"
            + "任务ID：\(taskId)\n"
            + "任务目标与输入：\n\(task)\n\n"
            + "交卷标准：\n\(expect)\n\n"
            + "\(imgHint)"
            + "\(fileHint)"
            + "完成后直接输出结果本身（纯内容，不要包装成 JSON、不要附加格式说明）。"
        )
    }

    // ════════════════════════════════════════════════════════
    // MARK: - 附件通道（loop.py L837-1045 移植）
    // ════════════════════════════════════════════════════════

    public static let maxDelegationImages = 50      // _MAX_DELEGATION_IMAGES
    public static let maxDelegationImageMB = 10     // _MAX_DELEGATION_IMAGE_MB
    public static let maxDelegationFiles = 20       // _MAX_DELEGATION_FILES

    /// _MIME_BY_EXT（图片扩展名 → mime）。
    public static let mimeByExt: [String: String] = [
        ".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg",
        ".webp": "image/webp", ".gif": "image/gif", ".bmp": "image/bmp",
    ]

    /// _DELEGATION_FILE_EXTS（可经 file_paths 传递的扩展名白名单）。
    public static let delegationFileExts: Set<String> = [
        ".docx", ".xlsx", ".xlsm", ".pptx", ".pdf", ".doc", ".xls", ".ppt",
        ".txt", ".md", ".markdown", ".csv", ".json", ".log", ".html", ".htm", ".xml",
    ]

    /// _IMAGE_INTENT_RE（REQ-AGT-019：大小写不敏感；⛔ 刻意不含裸"识别"）。
    public static let imageIntentPattern = "图片|图像|照片|截图|OCR|识图|看图|图中|影像|扫描件"

    /// _IMAGE_INTENT_RE.search：命中返回匹配到的关键词，否则 nil。
    public static func imageIntentMatch(_ text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: imageIntentPattern,
                                                options: .caseInsensitive) else { return nil }
        let ns = text as NSString
        guard let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }
        return ns.substring(with: m.range)
    }

    /// 裸文件名自纠正索引（0.4.9 F3）：sandbox 全量文件名 → 命中路径列表。
    /// 一次性构建、全批复用（单案件目录可达上百 MB，逐个 rglob 会显著拖慢）。
    private static func buildNameIndex(_ sandboxRoot: String) -> [String: [String]] {
        var index: [String: [String]] = [:]
        let root = URL(fileURLWithPath: (sandboxRoot as NSString).expandingTildeInPath)
        guard let en = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]) else { return index }
        for case let url as URL in en {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else {
                continue
            }
            index[url.lastPathComponent, default: []].append(url.path)
        }
        return index
    }

    private static func isFile(_ p: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: p, isDirectory: &isDir) && !isDir.boolValue
    }

    /// _load_delegation_images：图片路径列表 → (data URI 列表, 跳过的路径列表)。
    /// 单张失败不阻塞：解析失败/不存在/非图片扩展名/超 10MB → 跳过；超 50 张截断。
    public static func loadDelegationImages(_ imagePaths: [String]?, sandboxRoot: String)
        -> (loaded: [String], skipped: [String]) {
        var loaded: [String] = []
        var skipped: [String] = []
        let paths = (imagePaths ?? []).filter { !pyTrim($0).isEmpty }
        var nameIndex: [String: [String]] = [:]
        var indexBuilt = false

        for rel in paths.prefix(maxDelegationImages) {
            var resolved = NativeToolSandbox.resolveSandboxedPath(pyTrim(rel), sandboxRoot: sandboxRoot)
            if (resolved == nil || !isFile(resolved!))
                && !(pyTrim(rel) as NSString).isAbsolutePath {
                if !indexBuilt { nameIndex = buildNameIndex(sandboxRoot); indexBuilt = true }
                // 唯一命中才采用；多处同名不猜（避免拿错图），仍标记跳过
                let hits = nameIndex[(pyTrim(rel) as NSString).lastPathComponent] ?? []
                if hits.count == 1 { resolved = hits[0] }
            }
            guard let path = resolved, isFile(path) else { skipped.append(rel); continue }
            let ext = ("." + (path as NSString).pathExtension).lowercased()
            guard let mime = mimeByExt[ext] else { skipped.append(rel); continue }
            let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
            if size > maxDelegationImageMB * 1024 * 1024 { skipped.append(rel); continue }
            guard let data = FileManager.default.contents(atPath: path) else {
                skipped.append(rel); continue
            }
            loaded.append("data:\(mime);base64,\(data.base64EncodedString())")
        }
        if paths.count > maxDelegationImages {
            skipped.append(contentsOf: paths.dropFirst(maxDelegationImages))
        }
        return (loaded, skipped)
    }

    /// _resolve_delegation_files：委派文档路径 → (解析成功绝对路径列表, 跳过列表)。
    /// ⛔ 只做路径解析，不读文件内容（读的动作交给子 Agent，主 Agent 上下文不被撑爆）。
    public static func resolveDelegationFiles(_ filePaths: [String]?, sandboxRoot: String)
        -> (resolved: [String], skipped: [String]) {
        var resolvedOk: [String] = []
        var skipped: [String] = []
        let paths = (filePaths ?? []).filter { !pyTrim($0).isEmpty }
        var nameIndex: [String: [String]] = [:]
        var indexBuilt = false

        for rawRel in paths.prefix(maxDelegationFiles) {
            let rel = pyTrim(rawRel)
            var resolved = NativeToolSandbox.resolveSandboxedPath(rel, sandboxRoot: sandboxRoot)
            if (resolved == nil || !isFile(resolved!)) && !(rel as NSString).isAbsolutePath {
                if !indexBuilt { nameIndex = buildNameIndex(sandboxRoot); indexBuilt = true }
                let hits = nameIndex[(rel as NSString).lastPathComponent] ?? []
                if hits.count == 1 { resolved = hits[0] }
            }
            guard let path = resolved, isFile(path) else { skipped.append(rel); continue }
            let ext = ("." + (path as NSString).pathExtension).lowercased()
            guard delegationFileExts.contains(ext) else { skipped.append(rel); continue }
            resolvedOk.append(path)
        }
        if paths.count > maxDelegationFiles {
            skipped.append(contentsOf: paths.dropFirst(maxDelegationFiles).map { pyTrim($0) })
        }
        return (resolvedOk, skipped)
    }

    /// 真实清单（_real_images_hint / _real_docs_hint 共用骨架）。
    private static func realHint(sandboxRoot: String, exts: Set<String>, limit: Int,
                                 unit: String, emptyNote: String) -> String {
        let root = URL(fileURLWithPath: (sandboxRoot as NSString).expandingTildeInPath)
        guard let en = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]) else { return "（无法列出工作目录）" }
        var hits: [String] = []
        for case let url as URL in en {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else {
                continue
            }
            if exts.contains(("." + url.pathExtension).lowercased()) { hits.append(url.path) }
        }
        hits.sort()
        if hits.isEmpty { return "（工作目录 \(root.path) 下未找到任何\(emptyNote)）" }
        let shown = hits.prefix(limit)
        let lines = shown.map { "  - \($0)" }.joined(separator: "\n")
        let more = hits.count > limit
            ? "\n  …（另有 \(hits.count - shown.count) \(unit)未列出，可 list_dir 查看）" : ""
        return "\n共 \(hits.count) \(unit)：\n\(lines)\(more)"
    }

    /// _real_images_hint：工作目录下真实存在的图片清单（报错自纠正用）。
    public static func realImagesHint(_ sandboxRoot: String, limit: Int = 30) -> String {
        realHint(sandboxRoot: sandboxRoot, exts: Set(mimeByExt.keys), limit: limit,
                 unit: "张", emptyNote: "图片文件")
    }

    /// _real_docs_hint：工作目录下真实存在的文档/文本清单（拦截报错用；不含图片）。
    public static func realDocsHint(_ sandboxRoot: String, limit: Int = 30) -> String {
        realHint(sandboxRoot: sandboxRoot, exts: delegationFileExts, limit: limit,
                 unit: "个", emptyNote: "文档/文本文件")
    }
}

// ════════════════════════════════════════════════════════════
// MARK: - 串行锁 / 取消标志 / 共享状态（delegation.py L55-90）
// ════════════════════════════════════════════════════════════

/// _DELEGATION_LOCK 等价（决策 4 串行锁）：同一时刻只有一个子任务在推理。
/// FIFO 等待；等待中被取消 → 摘除等待者并放行（acquire 返回 false），
/// 调用方 isCancelled 自查兜底（DBG-140 先例：锁内登记后必须自查）。
/// NSLock + continuation 实现（非 actor）：release 同步语义，defer 中可直接调用。
public final class NativeDelegationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var held = false
    private var waiters: [Int: CheckedContinuation<Bool, Never>] = [:]
    private var nextId = 0

    public init() {}

    /// 获取锁；返回 false = 等待期间被取消（未持有锁，调用方不得 release）。
    public func acquire() async -> Bool {
        lock.lock()
        if !held { held = true; lock.unlock(); return true }
        let wid = nextId
        nextId += 1
        lock.unlock()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { cont in
                lock.lock()
                if !held {
                    // 登记前锁恰好已释放（竞态窗口）→ 直接拿下
                    held = true
                    lock.unlock()
                    cont.resume(returning: true)
                } else {
                    waiters[wid] = cont
                    lock.unlock()
                }
            }
        } onCancel: {
            lock.lock()
            let w = waiters.removeValue(forKey: wid)
            lock.unlock()
            // 与 release 竞速：谁先从 waiters 摘除谁生效（绝不双重 resume）
            w?.resume(returning: false)
        }
    }

    /// 释放锁（同步）：有等待者按 FIFO 移交，否则标记空闲。
    public func release() {
        lock.lock()
        if let first = waiters.min(by: { $0.key < $1.key }) {
            waiters[first.key] = nil
            lock.unlock()
            first.value.resume(returning: true)
        } else {
            held = false
            lock.unlock()
        }
    }
}

/// 活性超时错误（checkpoint-068 D-7；asyncio.TimeoutError 等价）。
public enum NativeDelegationError: Error, Equatable {
    case activityTimeout
}

// ════════════════════════════════════════════════════════════
// MARK: - 委派执行器（run_delegated_task + loop.py 路由段）
// ════════════════════════════════════════════════════════════

/// run_delegated_task 的入参包（对齐 delegation.py 形参表）。
public struct NativeDelegationTaskRequest: Sendable {
    public var projectId: String
    public var parentAgentId: String
    public var parentSessionId: String
    public var targetAgent: NativeDatabase.AgentConfigRow
    public var task: String
    public var expect: String
    public var sandboxRoot: String
    public var maxRounds: Int
    public var images: [String]?
    public var filePaths: [String]?
    public var simpleMode: Bool?
    public var modelOverride: String?

    public init(projectId: String, parentAgentId: String, parentSessionId: String,
                targetAgent: NativeDatabase.AgentConfigRow, task: String, expect: String,
                sandboxRoot: String, maxRounds: Int = 200,
                images: [String]? = nil, filePaths: [String]? = nil,
                simpleMode: Bool? = nil, modelOverride: String? = nil) {
        self.projectId = projectId
        self.parentAgentId = parentAgentId
        self.parentSessionId = parentSessionId
        self.targetAgent = targetAgent
        self.task = task
        self.expect = expect
        self.sandboxRoot = sandboxRoot
        self.maxRounds = maxRounds
        self.images = images
        self.filePaths = filePaths
        self.simpleMode = simpleMode
        self.modelOverride = modelOverride
    }
}

public final class NativeDelegationEngine: NativeDelegationRunner, @unchecked Sendable {

    public let db: NativeDatabase
    public let connector: any NativeChatConnector
    public let authorizer: (any NativeToolAuthorizer)?
    public let toolContext: NativeToolContext?
    public let toolExecutor: (any NativeLoopToolExecutor)?
    public let configProvider: @Sendable () -> [String: JSONValue]
    /// list_models 等价（模型存在性校验）；nil = 查询失败降级为空名单 → 跳过校验。
    public let listModels: (@Sendable () async -> [String])?
    /// model_supports_vision 元数据探测（名称层判不了时）；nil/失败 → true 不阻塞。
    public let visionProbe: (@Sendable (String) async -> Bool)?
    /// safe_unload_model 等价（0.4.9 换装编排）；nil = 无操作。
    public let safeUnloadModel: (@Sendable (String) async -> Bool)?
    /// REQ-AGT-020：委派写子会话消息后的变更通知钩（参数：projectId/sessionId/messageRole）。
    /// P2-W4d 起四处写点默认已硬连线 A13 真总线（NativeAppEvents）；本钩为叠加的
    /// 测试/装配缝（注入后总线仍触发，二者不互斥）。
    public let childSessionNotifier: (@Sendable (String, String, String) -> Void)?
    /// 交卷全文落盘（_finalize_summary；nil = 默认导出目录实现）。
    public let reportSaver: (@Sendable (String, String, [String: JSONValue], String) -> String?)?
    /// TS-110 M4：知识/记忆/技能注入 provider（nil = 降级为空，不阻塞委派）。
    public let knowledgeTextProvider: (@Sendable (String) -> String)?
    public let memoryInjectionProvider: (@Sendable (String) -> (String, [String]))?
    public let skillsListTextProvider: (@Sendable () -> String)?

    /// 测试接缝盒（coreOverride 的存储；见 extension 中的访问面）。
    let overrideBox = NativeLockedBox<((NativeDelegationTaskRequest) async -> [String: JSONValue])?>(nil)

    public init(db: NativeDatabase, connector: any NativeChatConnector,
                authorizer: (any NativeToolAuthorizer)? = nil,
                toolContext: NativeToolContext? = nil,
                toolExecutor: (any NativeLoopToolExecutor)? = nil,
                configProvider: @escaping @Sendable () -> [String: JSONValue] = { [:] },
                listModels: (@Sendable () async -> [String])? = nil,
                visionProbe: (@Sendable (String) async -> Bool)? = nil,
                safeUnloadModel: (@Sendable (String) async -> Bool)? = nil,
                childSessionNotifier: (@Sendable (String, String, String) -> Void)? = nil,
                reportSaver: (@Sendable (String, String, [String: JSONValue], String) -> String?)? = nil,
                knowledgeTextProvider: (@Sendable (String) -> String)? = nil,
                memoryInjectionProvider: (@Sendable (String) -> (String, [String]))? = nil,
                skillsListTextProvider: (@Sendable () -> String)? = nil) {
        self.db = db
        self.connector = connector
        self.authorizer = authorizer
        self.toolContext = toolContext
        self.toolExecutor = toolExecutor
        self.configProvider = configProvider
        self.listModels = listModels
        self.visionProbe = visionProbe
        self.safeUnloadModel = safeUnloadModel
        self.childSessionNotifier = childSessionNotifier
        self.reportSaver = reportSaver
        self.knowledgeTextProvider = knowledgeTextProvider
        self.memoryInjectionProvider = memoryInjectionProvider
        self.skillsListTextProvider = skillsListTextProvider
    }

    func config() -> [String: JSONValue] { configProvider() }

    // MARK: 共享状态（_DELEGATION_CANCEL / _LAST_DELEGATED_MODEL / 串行锁）

    /// _DELEGATION_LOCK 等价（进程级共享：多引擎实例也串行，对齐 Python 模块锁）。
    public static let serialGate = NativeDelegationGate()

    private static let cancelLock = NSLock()
    private static var cancelFlags: Set<String> = []
    private static let modelLock = NSLock()
    private static var lastDelegatedModel: [String: String] = [:]

    /// request_delegation_cancel（TS-114）：置取消标志，检查点检测到即中止。
    public static func requestDelegationCancel(_ taskId: String) {
        cancelLock.lock(); cancelFlags.insert(taskId); cancelLock.unlock()
    }

    /// clear_delegation_cancel（标志残留清理，防误伤后续重试）。
    public static func clearDelegationCancel(_ taskId: String) {
        cancelLock.lock(); cancelFlags.remove(taskId); cancelLock.unlock()
    }

    /// _is_delegation_cancelled。
    public static func isDelegationCancelled(_ taskId: String) -> Bool {
        cancelLock.lock(); defer { cancelLock.unlock() }
        return cancelFlags.contains(taskId)
    }

    /// 测试隔离专用：清空共享状态（生产不得调用）。
    public static func resetSharedState() {
        cancelLock.lock(); cancelFlags.removeAll(); cancelLock.unlock()
        modelLock.lock(); lastDelegatedModel.removeAll(); modelLock.unlock()
    }

    // MARK: 配置读取（get_config().get(...) + 异常降级默认值）

    private func configInt(_ key: String, _ def: Int) -> Int {
        guard let raw = config()[key], let f = PySem.toFloat(raw) else { return def }
        return Int(f)
    }

    private func configDouble(_ key: String, _ def: Double) -> Double {
        guard let raw = config()[key], let f = PySem.toFloat(raw) else { return def }
        return f
    }

    private func configBool(_ key: String, _ def: Bool) -> Bool {
        config()[key]?.bool ?? def
    }

    // MARK: 目标解析（决策 8）与自动新建（决策 9/10）

    /// resolve_target：精确（id 或 name，忽略大小写/首尾空白）→ 模糊（互为子串，
    /// 多命中取 name 最短）→ 未命中列出可用名单。候选一律排除发起者自己。
    public static func resolveTarget(db: NativeDatabase, projectId: String, target: String,
                                     selfAgentId: String) -> (NativeDatabase.AgentConfigRow?, String) {
        let t = NativeDelegation.pyTrim(target)
        guard !t.isEmpty else {
            return (nil, "delegate_task 需要 target/task/expect 三个参数，请补全。")
        }
        let candidates = ((try? db.listAgentConfigs(projectId: projectId)) ?? [])
            .filter { $0.id != selfAgentId }
        let tl = t.lowercased()
        // 1) 精确匹配
        for a in candidates {
            if a.id == t || NativeDelegation.pyTrim(a.name).lowercased() == tl {
                return (a, "")
            }
        }
        // 2) 模糊匹配（互为子串）
        let fuzzy = candidates.filter {
            let nl = $0.name.lowercased()
            return nl.contains(tl) || tl.contains(nl)
        }
        if fuzzy.count == 1 { return (fuzzy[0], "") }
        if fuzzy.count > 1 {
            let best = fuzzy.min { NativeDelegation.pyLen($0.name) < NativeDelegation.pyLen($1.name) }!
            return (best, "")
        }
        // 3) 未命中
        let names = candidates.map { $0.name }.joined(separator: "、")
        return (nil, "未找到名为「\(target)」的 Agent。当前可用："
                + (names.isEmpty ? "（当前没有其他 Agent）" : names) + "。请从中选择。")
    }

    /// auto_create_agent：按建议角色自动新建子 Agent；重名追加 -2/-3…（取最小可用号）。
    @discardableResult
    public static func autoCreateAgent(db: NativeDatabase, projectId: String,
                                       suggestedRole: String, modelName: String)
        -> NativeDatabase.AgentConfigRow {
        let base = NativeDelegation.pyTrim(suggestedRole).isEmpty
            ? "子Agent" : NativeDelegation.pyTrim(suggestedRole)
        let existing = Set(((try? db.listAgentConfigs(projectId: projectId)) ?? [])
            .map { NativeDelegation.pyTrim($0.name) })
        var name = base
        var n = 2
        while existing.contains(name) {
            name = "\(base)-\(n)"
            n += 1
        }
        let aid = (try? db.addAgentConfig(projectId: projectId, name: name, type: "sub",
                                          role: base, modelName: modelName)) ?? ""
        if let row = try? db.getAgentConfig(projectId: projectId, agentId: aid) {
            return row
        }
        return NativeDatabase.AgentConfigRow(id: aid, name: name, role: base,
                                             systemPrompt: nil, modelName: modelName,
                                             type_: "sub", parentAgentId: nil)
    }

    // MARK: D-8 前置守卫（去重 + 失败重试上限）

    /// _dup_or_over_retry_limit：返回 (重复任务ID 或 nil, 相同任务文本的历史失败数)。
    static func dupOrOverRetryLimit(db: NativeDatabase, projectId: String,
                                    targetAgentId: String, task: String) -> (String?, Int) {
        let norm = NativeDelegation.normTaskText(task)
        var sameTextFailures = 0
        var dupId: String?
        let recent = (try? db.listRecentDelegationsToTarget(
            projectId: projectId, targetAgentId: targetAgentId, limit: 30)) ?? []
        for r in recent {
            if NativeDelegation.normTaskText(r.task) != norm { continue }
            if r.status == "failed" {
                sameTextFailures += 1
            } else if ["queued", "running", "done"].contains(r.status), dupId == nil {
                dupId = r.id
            }
        }
        return (dupId, sameTextFailures)
    }

    // MARK: 视觉能力守卫（TS-118）

    /// model_supports_vision：名称层命中 → true；否则 probe 元数据；nil/失败 → true。
    func modelSupportsVision(_ model: String) async -> Bool {
        if let hit = NativeDelegation.modelNameSuggestsVision(model) { return hit }
        guard let visionProbe else { return true }
        return await visionProbe(model)
    }
}

// ════════════════════════════════════════════════════════════
// MARK: - 子会话执行（_run_one_pass / _run_pass_with_timeout）
// ════════════════════════════════════════════════════════════

/// 一次子会话 loop 的产出（_run_one_pass 返回四元组等价）。
public struct NativeDelegationPassOutcome: Sendable {
    public var fullText: String
    public var steps: [[String: JSONValue]]
    public var error: String?
    public var promptEvalMax: Int
}

extension NativeDelegationEngine {

    /// _run_one_pass：跑一次子会话 loop。
    /// 子任务不做压缩交互：compact/thinking 事件按跳过处理（不弹窗、不中断）。
    /// #15 进度转发：token 不逐字转发（≥2s 一次 progress 带累计字数）；
    /// tool_call/tool_result 逐条转发；state 每轮一次作轮次进度信号。
    func runOnePass(model: String, msgs: [[String: JSONValue]], sandboxRoot: String,
                    maxRounds: Int, images: [String]?,
                    cancelCheck: @escaping @Sendable () -> Bool,
                    projectId: String, taskId: String) async throws -> NativeDelegationPassOutcome {
        var fullText = ""
        var steps: [[String: JSONValue]] = []
        var peMax = 0   // TS-116：本轮最大 prompt_eval_count
        // #15：进度转发开关（两者都给才转发，缺一即静默关闭，向后兼容旧调用）
        let emitBus = !projectId.isEmpty && !taskId.isEmpty
        var lastProg = Date.distantPast   // 上次 progress 推送时间

        func pushBus(_ event: String, _ data: [String: JSONValue]) {
            guard emitBus else { return }
            // 总线失败绝不影响委派（push 内部已不抛，此处语义对齐 _push 的 try/except）
            _ = NativeDelegationEvents.push(projectId, taskId, event, data)
        }

        let stream = NativeAgentLoop.runToolLoop(
            model: model, messages: msgs,
            // 0.4.9 F2：子 Agent 既不可再委派（防递归），也不可有联网安装权
            toolsSpecList: NativeAgentLoop.toolsSpec(withDelegation: false, withInstall: false),
            sandboxRoot: sandboxRoot, connector: connector, authorizer: authorizer,
            maxRounds: maxRounds, contextLimit: 0, firstRoundImages: images,
            cancelCheck: cancelCheck,
            toolContext: toolContext, toolExecutor: toolExecutor,
            configProvider: configProvider)

        for await ev in stream {
            if Task.isCancelled { throw CancellationError() }
            let d = ev.data
            switch ev.event {
            case "token":
                fullText += d["delta"]?.string ?? ""
                // #15：token 节流转发（≥2s 一次），面板显示"已生成 N 字"而非逐字刷屏
                if Date().timeIntervalSince(lastProg) >= 2.0 {
                    lastProg = Date()
                    pushBus("progress", ["chars": .int(Int64(NativeDelegation.pyLen(fullText)))])
                }
            case "tool_call":
                steps.append(["id": .string(d["id"]?.string ?? ""),
                              "name": .string(d["name"]?.string ?? ""),
                              "args": d["args"] ?? .object([:]),
                              "status": .string("running")])
                // #15：面板实时显示"正在调用 X"——用户最想看到的中途进度
                pushBus("tool_call", ["name": .string(d["name"]?.string ?? ""),
                                      "id": .string(d["id"]?.string ?? "")])
            case "tool_result":
                let name = d["name"]?.string ?? ""
                let ok = d["ok"]?.bool ?? true
                var entry: [String: JSONValue] = [
                    "name": .string(name), "ok": .bool(ok),
                    "error": d["error"] ?? .null,
                    "summary": d["summary"] ?? .null,
                    "status": .string(ok ? "ok" : "error"),
                ]
                if let last = steps.last,
                   last["name"]?.string == name, last["status"]?.string == "running" {
                    entry["id"] = last["id"] ?? .string("")
                    entry["args"] = last["args"] ?? .null
                    steps[steps.count - 1] = entry
                } else {
                    steps.append(entry)
                }
                // #15：工具执行完成，面板把该行从"正在调用"更新为成功/失败
                pushBus("tool_result", ["name": .string(name), "ok": .bool(ok),
                                        "id": .string(entry["id"]?.string ?? ""),
                                        "summary": entry["summary"] ?? .null])
            case "done":
                if let c = d["content"]?.string,
                   !NativeDelegation.pyTrim(c).isEmpty { fullText = c }
                pushBus("progress", ["chars": .int(Int64(NativeDelegation.pyLen(fullText))),
                                     "round_done": .bool(true)])
            case "error":
                let detail = d["detail"]?.string ?? "子任务执行出错"
                pushBus("status", ["state": .string("error"), "detail": .string(detail)])
                return NativeDelegationPassOutcome(fullText: fullText, steps: steps,
                                                   error: detail, promptEvalMax: peMax)
            case "cancelled":
                // TS-114：loop 检查点检测到取消标志 → 中止子会话
                pushBus("status", ["state": .string("cancelled")])
                return NativeDelegationPassOutcome(fullText: fullText, steps: steps,
                                                   error: "已停止", promptEvalMax: peMax)
            case "state":
                // TS-116：收集 prompt_eval_count 回传给主会话
                if let pe = d["prompt_eval_count"]?.int, pe > 0, pe > peMax {
                    peMax = Int(pe)
                }
                // #15：state 每轮一次，是天然的轮次进度信号（step/max/ctx_chars）
                pushBus("progress", ["step": d["step"] ?? .null,
                                     "max": d["max"] ?? .null,
                                     "ctx_chars": d["ctx_chars"] ?? .null,
                                     "chars": .int(Int64(NativeDelegation.pyLen(fullText)))])
            default:
                break   // compact_auto / compact_required / thinking：跳过
            }
        }
        if Task.isCancelled { throw CancellationError() }
        return NativeDelegationPassOutcome(fullText: fullText, steps: steps,
                                           error: nil, promptEvalMax: peMax)
    }

    /// _run_pass_with_timeout：活性超时包住一次子会话执行（0=不限制）。
    func runPassWithTimeout(model: String, msgs: [[String: JSONValue]], sandboxRoot: String,
                            maxRounds: Int, timeout: Double,
                            cancelCheck: @escaping @Sendable () -> Bool,
                            images: [String]?,
                            projectId: String, taskId: String) async throws -> NativeDelegationPassOutcome {
        guard timeout > 0 else {
            return try await runOnePass(model: model, msgs: msgs, sandboxRoot: sandboxRoot,
                                        maxRounds: maxRounds, images: images,
                                        cancelCheck: cancelCheck,
                                        projectId: projectId, taskId: taskId)
        }
        enum Race: Sendable {
            case value(NativeDelegationPassOutcome)
            case timedOut
        }
        return try await withThrowingTaskGroup(of: Race.self) { group in
            group.addTask {
                .value(try await self.runOnePass(model: model, msgs: msgs,
                                                 sandboxRoot: sandboxRoot,
                                                 maxRounds: maxRounds, images: images,
                                                 cancelCheck: cancelCheck,
                                                 projectId: projectId, taskId: taskId))
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return Race.timedOut
            }
            guard let first = try await group.next() else {
                group.cancelAll()
                throw NativeDelegationError.activityTimeout
            }
            group.cancelAll()
            switch first {
            case .value(let v): return v
            case .timedOut: throw NativeDelegationError.activityTimeout
            }
        }
    }
}

// ════════════════════════════════════════════════════════════
// MARK: - 交卷超长落盘（M7 TS-113：>1000 字确定性系统行为）
// ════════════════════════════════════════════════════════════

extension NativeDelegationEngine {

    /// _finalize_summary：summary ≤1000 字原样回传；>1000 字交卷全文落盘
    /// delegation_reports/，summary 回传前 1000 字 + 文件路径标注。落盘失败不阻塞（仅截断）。
    func finalizeSummary(projectId: String, taskId: String,
                         report: [String: JSONValue], fullText: String) -> [String: JSONValue] {
        var report = report
        let summary = report["summary"]?.string ?? ""
        guard NativeDelegation.pyLen(summary) > NativeDelegation.summaryMaxLen else { return report }
        let path = (reportSaver ?? defaultReportSaver)(projectId, taskId, report, fullText)
        if let path {
            report["summary"] = .string(NativeDelegation.pyPrefix(summary, NativeDelegation.summaryMaxLen)
                + "\n[交卷全文已保存：\(path)]")
            report["summary_saved_path"] = .string(path)
        } else {
            report["summary"] = .string(NativeDelegation.pyPrefix(summary, NativeDelegation.summaryMaxLen)
                + "\n[交卷全文过长已截断，落盘失败]")
        }
        return report
    }

    /// delegation.py _notify_child_session_changed 等价（REQ-AGT-020，0.4.28）：
    /// 写子会话消息后经 A13 资源总线广播 session 变更（P2-W4d 已接真总线）。
    /// 默认真总线硬连线（对齐 Python 模块内直调 app_events.notify）；
    /// childSessionNotifier 钩层保留为测试/装配附加缝（W4b 挂起期遗留，叠加触发）。
    /// ⛔ 只在委派写路径调用，绝不挂全局 saveMessage（主聊天热路径防事件风暴）。
    private func notifyChildSessionChanged(_ projectId: String, _ sessionId: String,
                                           role: String) {
        NativeAppEvents.notifyChildSessionChanged(projectId: projectId,
                                                  sessionId: sessionId, messageRole: role)
        childSessionNotifier?(projectId, sessionId, role)
    }

    /// exporter.resolve_export_dir 等价：config default_export_dir → 项目工作目录
    /// → <data_root>/exports 兜底（保证导出永不失败）。
    private func resolveExportDir(_ projectId: String) -> URL {
        let cfgDir = NativeDelegation.pyTrim(config()["default_export_dir"]?.string ?? "")
        if !cfgDir.isEmpty {
            let p = URL(fileURLWithPath: (cfgDir as NSString).expandingTildeInPath)
            try? FileManager.default.createDirectory(at: p, withIntermediateDirectories: true)
            let probe = p.appendingPathComponent(".subagent_export_probe")
            if (try? "ok".write(to: probe, atomically: true, encoding: .utf8)) != nil {
                try? FileManager.default.removeItem(at: probe)
                return p
            }
        }
        if let proj = try? db.getProject(projectId), !proj.workingDir.isEmpty {
            return URL(fileURLWithPath: (proj.workingDir as NSString).expandingTildeInPath)
        }
        // projectsRoot = <data_root>/projects → data_root/exports
        return db.projectsRoot.deletingLastPathComponent().appendingPathComponent("exports")
    }

    /// exporter.save_delegation_report_md 等价（写失败返回 nil，不阻塞委派）。
    private func defaultReportSaver(projectId: String, taskId: String,
                                    report: [String: JSONValue], fullText: String) -> String? {
        do {
            let outDir = resolveExportDir(projectId).appendingPathComponent("delegation_reports")
            try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
            let df = DateFormatter()
            df.dateFormat = "yyyyMMdd-HHmmss"
            let ts = df.string(from: Date())
            let safeTid = String(taskId.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
                .prefix(16))
            let path = outDir.appendingPathComponent("\(safeTid)-\(ts).md")
            let df2 = DateFormatter()
            df2.dateFormat = "yyyy-MM-dd HH:mm:ss"
            var lines = ["# 委派交卷全文",
                         "> 任务ID: \(taskId)",
                         "> 状态: \(report["status"]?.string ?? "")",
                         "> 落盘时间: \(df2.string(from: Date()))",
                         "",
                         "## 交卷 summary（全文）",
                         "",
                         report["summary"]?.string ?? "",
                         "",
                         "## artifacts",
                         ""]
            if case .array(let arts) = report["artifacts"] {
                for a in arts { lines.append("- \(NativeDelegation.pyStr(a))") }
            }
            lines += ["", "## 子 Agent 原始回复", "", fullText]
            try lines.joined(separator: "\n").write(to: path, atomically: true, encoding: .utf8)
            return path.path
        } catch {
            return nil
        }
    }
}

// ════════════════════════════════════════════════════════════
// MARK: - 委派执行器主体（run_delegated_task 逐行为）
// ════════════════════════════════════════════════════════════

extension NativeDelegationEngine {

    /// 测试接缝（对齐 Python 打桩 delegation.run_delegated_task 模块属性）：非 nil 时
    /// routeDelegateTask 用该闭包替代真实委派执行。⛔ 生产装配绝不可赋值。
    var coreOverride: ((NativeDelegationTaskRequest) async -> [String: JSONValue])? {
        get { overrideBox.withLock { $0 } }
        set { overrideBox.withLock { $0 = newValue } }
    }

    /// run_delegated_task：执行一次委派（默认串行锁内；task_concurrency 开启时并行）。
    /// 成功：{"ok": true, "task_id", "status", "summary", "artifacts", ...}
    /// 失败：{"ok": false, "task_id"?, "error": 缺失/失败原因}
    /// 取消：标 failed（中断）后上抛 CancellationError（asyncio.CancelledError 等价）。
    public func runDelegatedTask(_ req: NativeDelegationTaskRequest) async throws -> [String: JSONValue] {
        let projectId = req.projectId
        let targetAgent = req.targetAgent
        let targetAgentId = targetAgent.id
        let targetName = targetAgent.name.isEmpty ? String(targetAgentId.prefix(8)) : targetAgent.name
        var model = (targetAgent.modelName?.isEmpty == false) ? targetAgent.modelName! : "qwen3.8"

        // 0.4.9（3.47.2）：委派模型自选——model_override 覆盖子 Agent 默认模型
        var modelOverridden = false
        if let ov0 = req.modelOverride, !NativeDelegation.pyTrim(ov0).isEmpty {
            var ov = NativeDelegation.pyTrim(ov0)
            // 模型存在性校验：本地无此模型 → 报错并列出可用模型，不静默回退
            if let listModels {
                let avail = await listModels()
                if !avail.isEmpty && !avail.contains(ov) {
                    // 兼容带/不带 tag 的写法（"glm-ocr" 命中 "glm-ocr:latest"）；
                    // ⚠️ .vmodel 池名自身含 ":"（vmodel:<slug>）——tag 兜底会把
                    // 不存在的 slug 错配到首个 vmodel 条目，故只认精确命中（REQ-FUT-020）。
                    // 口径核对（ModelIdentity）：本处是「同 base 任意 tag 命中并重写为
                    // 列表名」的委派容错语义（比 ModelIdentity.sameModel 的严格
                    // ":latest" 互认更宽松），属有意保留，不收编、行为不变。
                    let ovBase = ov.split(separator: ":").first.map(String.init) ?? ov
                    if let hit = avail.first(where: {
                        $0 == ov || (!NativeVModelChat.isVModelName(ov)
                            && ($0.split(separator: ":").first.map(String.init) ?? $0) == ovBase)
                    }) {
                        ov = hit
                    } else {
                        return ["ok": .bool(false), "status": .string("failed"),
                                "task_id": .string(""),
                                "error": .string("model_not_found: 你指定的委派模型「\(ov)」在本机不存在。"
                                    + "可用模型：\(avail.prefix(12).joined(separator: "、"))。"
                                    + "请改用其中某个模型重新委派，或不填 model 参数沿用目标 Agent 自身模型。")]
                    }
                }
            }
            model = ov
            modelOverridden = true
        }

        // 0.1.71（TS-118）：简单模式判定（带图强制启用 / 显式传参 / OCR 专用模型）
        let simple = NativeDelegation.resolveSimpleMode(images: req.images, model: model,
                                                        simpleMode: req.simpleMode)

        // 0.1.71（TS-118）：带图委派视觉能力守卫——不支持图片输入直接拦截
        if let images = req.images, !images.isEmpty, !(await modelSupportsVision(model)) {
            return ["ok": .bool(false),
                    "error": .string("「\(targetName)」的模型 \(model) 不支持图片输入，无法完成带图任务。"
                        + "请改派多模态模型（如 qwen-vl / glm-ocr / llava 等）后再委派。")]
        }

        // checkpoint-068 D-8：委派前置守卫（去重 + 失败重试上限），在落库前拦截
        let (dupId, failedCount) = Self.dupOrOverRetryLimit(
            db: db, projectId: projectId, targetAgentId: targetAgentId, task: req.task)
        if let dupId {
            return ["ok": .bool(false),
                    "error": .string("相同任务已委派给「\(targetName)」（任务 \(String(dupId.prefix(8)))），"
                        + "请勿重复委派。可查看该任务结果，或调整任务书后再委派。")]
        }
        let maxRetries = configInt("delegation_max_retries", 2)
        if maxRetries > 0 && failedCount >= maxRetries {
            return ["ok": .bool(false),
                    "error": .string("「\(targetName)」已有 \(failedCount) 次失败（上限 \(maxRetries) 次），"
                        + "请勿继续重试同一委派。请向用户说明情况，建议调整任务书、更换目标或人工处理。")]
        }

        // checkpoint-068 D-7：活性超时（秒，0=关闭）
        let activityTimeout = configDouble("delegation_activity_timeout",
                                           NativeDelegation.defaultActivityTimeout)
        // checkpoint-068 D-4：任务并发开关（默认关 = 串行排队）
        let concurrent = configBool("task_concurrency", false)

        // TS-108（决策 4 排队语义）：先落库（status=queued），再等串行锁。
        let taskId: String
        do {
            taskId = try db.createAgentTask(
                projectId: projectId, parentAgentId: req.parentAgentId,
                parentSessionId: req.parentSessionId, targetAgentId: targetAgentId,
                targetAgentName: targetName, task: req.task, expect: req.expect)
        } catch {
            return ["ok": .bool(false),
                    "error": .string("委派任务落库失败：\(error.localizedDescription)")]
        }
        // 0.4.20（#15）：建事件通道并推 queued——面板无需等轮询就能看到任务已排队。
        NativeDelegationEvents.beginTask(projectId, taskId)
        _ = NativeDelegationEvents.push(projectId, taskId, "status",
            ["state": .string("queued"), "target_agent_name": .string(targetName)])
        // 0.4.20（#15）：⛔ 必须 defer——任何返回/异常/取消路径都要推 task_end
        // 并回收通道（否则订阅者永远等不到结束信号 → 前端转圈不停）。
        defer { NativeDelegationEvents.endTask(projectId, taskId) }

        // 决策 4 串行锁（task_concurrency 开启时跳过——_NOOP_LOCK 等价）
        var lockHeld = false
        if !concurrent {
            let granted = await Self.serialGate.acquire()
            if granted {
                lockHeld = true
                // DBG-140 兜底：拿到锁后再自查一次取消（等待期间可能已被取消）
                if Task.isCancelled {
                    Self.serialGate.release()
                    lockHeld = false
                    try? db.updateAgentTask(projectId: projectId, taskId: taskId,
                                            status: "failed",
                                            failReason: "委派被中断（用户停止或连接断开）")
                    throw CancellationError()
                }
            } else {
                // 等锁期间被取消（asyncio.wait_for 取消等锁 await 等价）
                try? db.updateAgentTask(projectId: projectId, taskId: taskId,
                                        status: "failed",
                                        failReason: "委派被中断（用户停止或连接断开）")
                throw CancellationError()
            }
        }
        defer { if lockHeld { Self.serialGate.release() } }

        do {
            try db.updateAgentTask(projectId: projectId, taskId: taskId, status: "running")
            // 0.4.20（#15）：拿到串行锁、开始执行 → 面板立刻从「等待中」变「进行中」
            _ = NativeDelegationEvents.push(projectId, taskId, "status",
                ["state": .string("running"), "target_agent_name": .string(targetName)])

            // TS-114（3.25）检查点1：排队期间被请求停止 → 直接标失败，不再发起模型调用
            if Self.isDelegationCancelled(taskId) {
                Self.clearDelegationCancel(taskId)
                try db.updateAgentTask(projectId: projectId, taskId: taskId, status: "failed",
                                       failReason: "用户已停止该委派任务（已停止，未执行）")
                return ["ok": .bool(false), "task_id": .string(taskId),
                        "error": .string("子 Agent「\(targetName)」任务已被用户停止。")]
            }

            // TS-116（3.21④）：model_parallel=false + 模型切换 → 等待 5s 让 Ollama GC 旧模型
            let modelParallel = configBool("model_parallel", false)
            if !modelParallel {
                Self.modelLock.lock()
                let last = Self.lastDelegatedModel[projectId]
                Self.modelLock.unlock()
                if let last, last != model {
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                }
            }
            Self.modelLock.lock()
            Self.lastDelegatedModel[projectId] = model
            Self.modelLock.unlock()

            // 上下文隔离（决策 2）：为子 Agent 新建独立会话，只有任务书，无主对话历史
            let childSid = try db.createSession(projectId: projectId, agentId: targetAgentId,
                                                title: "委派任务 \(String(taskId.prefix(8)))")
            try db.updateAgentTask(projectId: projectId, taskId: taskId, sessionId: childSid)

            let netSwitch = config()["network_switch"]?.string ?? "auto"
            // TS-110 M4：子 Agent 同样注入知识/记忆/技能；加载失败一律降级为空，不阻塞委派
            let kText = knowledgeTextProvider?(projectId) ?? ""
            let (mText, proh) = memoryInjectionProvider?(projectId) ?? ("", [])
            let skText = skillsListTextProvider?() ?? ""
            let sysPrompt = NativeAgentLoop.buildSystemPrompt(
                agentName: targetName, agentRole: targetAgent.role,
                sandboxRoot: req.sandboxRoot, networkSwitch: netSwitch,
                systemPrompt: targetAgent.systemPrompt,
                knowledgeText: kText, memoryText: mText, prohibitions: proh,
                skillsListText: skText)
                + (simple ? "" : NativeDelegation.reportContractPrompt)

            // 0.1.71（TS-118）：简单模式任务消息只留任务书本身；
            // #15（0.4.19）：file_paths 写进任务书【必读文件】段，由子 Agent 自己 read_file
            let imageCount = req.images?.count ?? 0
            let userMsg = simple
                ? NativeDelegation.taskUserMessageSimple(
                    taskId: taskId, task: req.task, expect: req.expect,
                    imageCount: imageCount, filePaths: req.filePaths)
                : NativeDelegation.taskUserMessage(
                    taskId: taskId, task: req.task, expect: req.expect,
                    imageCount: imageCount, filePaths: req.filePaths)
            // 0.1.71（TS-118）：委派附着的图片落库存档，子会话回看可见
            try db.saveMessage(projectId: projectId, sessionId: childSid, agentId: targetAgentId,
                               role: "user", content: userMsg,
                               images: (req.images?.isEmpty == false) ? req.images : nil)
            // REQ-AGT-020（0.4.28）：写子会话后广播 session 变更（P2-W4d：已接真总线；
            // ⛔ 绝不挂全局 saveMessage——主聊天热路径防事件风暴）
            notifyChildSessionChanged(projectId, childSid, role: "user")

            // TS-114（3.25）：本任务取消检查回调（loop 每轮开始前调用）
            let cancelCheck: @Sendable () -> Bool = { Self.isDelegationCancelled(taskId) }
            var peFinal = 0   // TS-116：交卷报告 prompt_eval_count（追问路径可能不赋值）
            var finalText = ""

            do {
                // 第一轮：任务书 → 子 Agent 执行 → 交卷
                var msgs: [[String: JSONValue]] = [
                    ["role": .string("system"), "content": .string(sysPrompt)],
                    ["role": .string("user"), "content": .string(userMsg)],
                ]
                let pass1 = try await runPassWithTimeout(
                    model: model, msgs: msgs, sandboxRoot: req.sandboxRoot,
                    maxRounds: req.maxRounds, timeout: activityTimeout,
                    cancelCheck: cancelCheck, images: req.images,
                    projectId: projectId, taskId: taskId)
                if pass1.promptEvalMax > 0 { peFinal = pass1.promptEvalMax }
                // TS-114（3.25）检查点2：第一轮结束后、交卷解析前
                if Self.isDelegationCancelled(taskId) {
                    Self.clearDelegationCancel(taskId)
                    try db.updateAgentTask(projectId: projectId, taskId: taskId, status: "failed",
                                           failReason: "用户已停止该委派任务（已停止）")
                    return ["ok": .bool(false), "task_id": .string(taskId),
                            "error": .string("子 Agent「\(targetName)」任务已被用户停止。")]
                }
                try db.saveMessage(projectId: projectId, sessionId: childSid,
                                   agentId: targetAgentId, role: "assistant",
                                   content: pass1.fullText, modelUsed: model,
                                   toolSteps: pass1.steps.isEmpty
                                       ? nil : .array(pass1.steps.map { .object($0) }))
                notifyChildSessionChanged(projectId, childSid, role: "assistant")   // REQ-AGT-020
                if let err1 = pass1.error {
                    try db.updateAgentTask(projectId: projectId, taskId: taskId,
                                           status: "failed", failReason: err1)
                    return ["ok": .bool(false), "task_id": .string(taskId),
                            "error": .string("子 Agent「\(targetName)」执行出错：\(err1)")]
                }

                var report: [String: JSONValue]?
                finalText = pass1.fullText
                if simple {
                    // 0.1.71（TS-118）：简单模式交卷——第一轮原文直接作为结果
                    report = NativeDelegation.buildSimpleReport(pass1.fullText, taskId: taskId)
                    if report == nil {
                        let reason = "子 Agent 未返回任何内容"
                        try db.updateAgentTask(projectId: projectId, taskId: taskId,
                                               status: "failed", failReason: reason)
                        return ["ok": .bool(false), "task_id": .string(taskId),
                                "error": .string("子 Agent「\(targetName)」\(reason)，"
                                    + "请检查图片可读性后重试。")]
                    }
                } else {
                    report = NativeDelegation.parseReport(pass1.fullText, taskId: taskId)
                }

                if report == nil {
                    // TS-114（3.25）检查点3：追问前
                    if Self.isDelegationCancelled(taskId) {
                        Self.clearDelegationCancel(taskId)
                        try db.updateAgentTask(projectId: projectId, taskId: taskId,
                                               status: "failed",
                                               failReason: "用户已停止该委派任务（已停止）")
                        return ["ok": .bool(false), "task_id": .string(taskId),
                                "error": .string("子 Agent「\(targetName)」任务已被用户停止。")]
                    }
                    // 追问 1 次（决策 3）：子会话完整历史 + 固定追问文案
                    let retryMsg = NativeDelegation.retryPrompt(taskId: taskId)
                    try db.saveMessage(projectId: projectId, sessionId: childSid,
                                       agentId: targetAgentId, role: "user", content: retryMsg)
                    notifyChildSessionChanged(projectId, childSid, role: "user")   // REQ-AGT-020
                    msgs.append(["role": .string("assistant"), "content": .string(pass1.fullText)])
                    msgs.append(["role": .string("user"), "content": .string(retryMsg)])
                    let pass2 = try await runPassWithTimeout(
                        model: model, msgs: msgs, sandboxRoot: req.sandboxRoot,
                        maxRounds: req.maxRounds, timeout: activityTimeout,
                        cancelCheck: cancelCheck, images: nil,
                        projectId: projectId, taskId: taskId)
                    if pass2.promptEvalMax > 0 { peFinal = pass2.promptEvalMax }
                    // TS-114（3.25）检查点4：追问结束后
                    if Self.isDelegationCancelled(taskId) {
                        Self.clearDelegationCancel(taskId)
                        try db.updateAgentTask(projectId: projectId, taskId: taskId,
                                               status: "failed",
                                               failReason: "用户已停止该委派任务（已停止）")
                        return ["ok": .bool(false), "task_id": .string(taskId),
                                "error": .string("子 Agent「\(targetName)」任务已被用户停止。")]
                    }
                    try db.saveMessage(projectId: projectId, sessionId: childSid,
                                       agentId: targetAgentId, role: "assistant",
                                       content: pass2.fullText, modelUsed: model,
                                       toolSteps: pass2.steps.isEmpty
                                           ? nil : .array(pass2.steps.map { .object($0) }))
                    notifyChildSessionChanged(projectId, childSid, role: "assistant")   // REQ-AGT-020
                    finalText = pass2.fullText
                    if let err2 = pass2.error {
                        try db.updateAgentTask(projectId: projectId, taskId: taskId,
                                               status: "failed", failReason: err2,
                                               validationFailures: 1)
                        return ["ok": .bool(false), "task_id": .string(taskId),
                                "error": .string("子 Agent「\(targetName)」执行出错：\(err2)")]
                    }
                    report = NativeDelegation.parseReport(pass2.fullText, taskId: taskId)
                    if report == nil {
                        // H17 问题4：兜底打包——弱模型确实干了活但没按契约交卷
                        report = NativeDelegation.buildFallbackReport(pass2.fullText, taskId: taskId)
                    }
                    if report == nil {
                        let reason = "交卷格式两次校验未通过"
                        try db.updateAgentTask(projectId: projectId, taskId: taskId,
                                               status: "failed", failReason: reason,
                                               validationFailures: 2)
                        return ["ok": .bool(false), "task_id": .string(taskId),
                                "error": .string("子 Agent「\(targetName)」两次交卷均未通过格式校验，"
                                    + "该子任务标记异常。缺失的产出："
                                    + NativeDelegation.pyPrefix(req.expect, 200))]
                    }
                }

                // M7（TS-113）交卷契约扩容 + TS-116（3.20③）prompt_eval_count 回传
                if peFinal > 0 { report!["prompt_eval_count"] = .int(Int64(peFinal)) }
                let finalReport = finalizeSummary(projectId: projectId, taskId: taskId,
                                                  report: report!, fullText: finalText)
                Self.clearDelegationCancel(taskId)   // TS-114：标志残留清理（防误伤后续重试）
                try db.updateAgentTask(projectId: projectId, taskId: taskId, status: "done",
                                       report: NativeDatabase.dumpsUTF8(.object(finalReport)))
                // 0.4.20（#15）：交卷成功 → 面板立刻显示完成与摘要
                _ = NativeDelegationEvents.push(projectId, taskId, "status", [
                    "state": .string("done"),
                    "report_status": finalReport["status"] ?? .null,
                    "summary": .string(NativeDelegation.pyPrefix(
                        finalReport["summary"]?.string ?? "", 300)),
                ])
                // checkpoint-068（3.21 D-2）：委派成功后自动清理子 Agent 与会话
                // （开关 + 交卷确实 success + 仅 sub 型；清理失败不影响主流程）
                if configBool("delegation_auto_cleanup", false),
                   finalReport["status"]?.string == "success",
                   let cfg = try? db.getAgentConfig(projectId: projectId, agentId: targetAgentId),
                   cfg.type_ == "sub" {
                    try? db.deleteSession(projectId: projectId, sessionId: childSid)
                    try? db.removeAgentConfig(projectId: projectId, agentId: targetAgentId)
                }
                return ["ok": .bool(true), "task_id": .string(taskId),
                        "status": finalReport["status"] ?? .string(""),
                        "summary": finalReport["summary"] ?? .string(""),
                        "artifacts": finalReport["artifacts"] ?? .array([]),
                        "target_agent_name": .string(targetName),
                        // 0.4.9（3.47.2）：报告本次实际使用的模型
                        "model_used": .string(model),
                        "model_overridden": .bool(modelOverridden)]
            } catch NativeDelegationError.activityTimeout {
                // checkpoint-068 D-7：活性超时 → 判卡死，标记失败并中止
                let reason = "活性超时：子任务 \(Int(activityTimeout)) 秒内未完成（疑似模型僵死），已中止"
                try? db.updateAgentTask(projectId: projectId, taskId: taskId,
                                        status: "failed", failReason: reason)
                return ["ok": .bool(false), "task_id": .string(taskId),
                        "error": .string("子 Agent「\(targetName)」\(reason)。请勿盲目重试同一任务。")]
            } catch let e as CancellationError {
                throw e   // 由外层统一标记中断
            } catch {
                // 兜底：任何异常都不允许穿透到主 loop
                try? db.updateAgentTask(projectId: projectId, taskId: taskId,
                                        status: "failed", failReason: "\(error)")
                return ["ok": .bool(false), "task_id": .string(taskId),
                        "error": .string("子 Agent「\(targetName)」执行出错：\(error)")]
            }
        } catch is CancellationError {
            // 客户端停止主会话（含排队等锁期间被停止）→ 标记中断后继续上抛
            try? db.updateAgentTask(projectId: projectId, taskId: taskId, status: "failed",
                                    failReason: "委派被中断（用户停止或连接断开）")
            throw CancellationError()
        }
    }
}

// ════════════════════════════════════════════════════════════
// MARK: - delegate_task 路由（loop.py L1822-2017 逐行为）
// ════════════════════════════════════════════════════════════

extension NativeDelegationEngine {

    /// loop.py delegate_task 路由段本体：参数校验 → F1 附件拦截 → REQ-AGT-019
    /// 零图守卫 → 目标解析/自动新建 → 模型换装编排 → run_delegated_task → 结果标注。
    public func routeDelegateTask(args: [String: JSONValue], projectId: String,
                                  agentId: String, sessionId: String, parentModel: String,
                                  sandboxRoot: String, maxRounds: Int,
                                  firstRoundImages: [String]?) async throws -> [String: JSONValue] {
        let taskArg = NativeDelegation.pyTrim(args["task"]?.string ?? "")
        let expectArg = NativeDelegation.pyTrim(args["expect"]?.string ?? "")
        let targetArg = NativeDelegation.pyTrim(args["target"]?.string ?? "")
        let roleArg = NativeDelegation.pyTrim(args["suggested_role"]?.string ?? "")
        // 0.4.9（3.47.2）：委派模型自选
        let modelArg = NativeDelegation.pyTrim(args["model"]?.string ?? "")
        // 0.1.71（TS-118）：target 必填回错——漏填时列出可用 Agent 名单，绝不静默新建
        guard !taskArg.isEmpty, !expectArg.isEmpty, !targetArg.isEmpty else {
            let names = (((try? db.listAgentConfigs(projectId: projectId)) ?? [])
                .filter { $0.id != agentId }.map { $0.name }).joined(separator: "、")
            return NativeAgentLoop.err(
                "delegate_task 需要 target（目标 Agent 名称）/task/expect 三个参数，"
                + "请补全后重新调用。当前可用 Agent：\(names.isEmpty ? "（暂无其他 Agent）" : names)。")
        }

        var result: [String: JSONValue] = [:]
        var f1Blocked = false

        // TS-117（3.31 任务2）：加载 image_paths 图片 → base64，随委派传给子 Agent
        var loadedImages: [String] = []
        var skippedPaths: [String] = []
        let imagePaths = args["image_paths"]?.stringArray ?? []
        // 0.4.9 F1：图片全部加载失败 → 拦截委派（哨兵短路后续解析/新建/执行）
        if !imagePaths.isEmpty {
            (loadedImages, skippedPaths) = NativeDelegation.loadDelegationImages(
                imagePaths, sandboxRoot: sandboxRoot)
            if loadedImages.isEmpty {
                f1Blocked = true
                result = NativeAgentLoop.err(
                    "images_not_found: 你传入的 image_paths 一张都没找到，"
                    + "已跳过 \(skippedPaths.count) 个（\(NativeDelegation.pyListRepr(Array(skippedPaths.prefix(5))))"
                    + "\(skippedPaths.count > 5 ? "…" : "")）。"
                    + "委派已中止——若继续，子 Agent 将收不到任何图片而只能编造识别结果。"
                    + "请改用【完整绝对路径】重试；以下是工作目录下真实存在的图片："
                    + NativeDelegation.realImagesHint(sandboxRoot))
            }
        }

        // #15（0.4.19）：文档路径通道——只解析路径，由【子 Agent 自己 read_file】
        var resolvedFiles: [String] = []
        var skippedFiles: [String] = []
        let filePaths = args["file_paths"]?.stringArray ?? []
        if !filePaths.isEmpty && !f1Blocked {
            (resolvedFiles, skippedFiles) = NativeDelegation.resolveDelegationFiles(
                filePaths, sandboxRoot: sandboxRoot)
            if resolvedFiles.isEmpty {
                f1Blocked = true
                result = NativeAgentLoop.err(
                    "files_not_found: 你传入的 file_paths 一个都没找到，"
                    + "已跳过 \(skippedFiles.count) 个（\(NativeDelegation.pyListRepr(Array(skippedFiles.prefix(5))))"
                    + "\(skippedFiles.count > 5 ? "…" : "")）。"
                    + "委派已中止——若继续，子 Agent 将读不到任何文件而只能编造内容。"
                    + "请改用【完整绝对路径】重试；以下是工作目录下真实存在的文档："
                    + NativeDelegation.realDocsHint(sandboxRoot))
            }
        }

        // REQ-AGT-019（0.4.28）：零图片 + 图片意图守卫（合并图片之后、发起委派之前）
        if !f1Blocked && (firstRoundImages ?? []).isEmpty && loadedImages.isEmpty,
           let intentHit = NativeDelegation.imageIntentMatch("\(taskArg)\n\(expectArg)") {
            f1Blocked = true
            result = NativeAgentLoop.err(
                "images_missing: 任务书含图片意图（命中「\(intentHit)」），"
                + "但本次委派一张图片都没有：既没有聊天附着图，"
                + "也未通过 image_paths 传入任何图片。委派已中止——若继续，"
                + "子 Agent 将收不到任何图片，只能回答“不支持OCR”或编造识别结果。\n"
                + "图片有两条通道：\n"
                + "① 聊天附着图：附着在消息里的图片会在【每次委派时全量自动携带】，"
                + "无需传参——但它无法按批拆分；\n"
                + "② 文件夹图片：必须用 image_paths 参数传【该批图片的绝对路径列表】"
                + "（可先 list_dir 盘点工作目录拼路径；分批委派时每批传该批子集）。\n"
                + "请按上述通道补图后重新委派；以下是工作目录下真实存在的图片："
                + NativeDelegation.realImagesHint(sandboxRoot))
        }

        // 目标解析（决策 8）+ suggested_role 兜底搜索（0.1.71）+ 自动新建（决策 9）
        var agent: NativeDatabase.AgentConfigRow?
        var terr = ""
        var autoCreated = false
        if !f1Blocked {
            let (a, e) = Self.resolveTarget(db: db, projectId: projectId,
                                            target: targetArg, selfAgentId: agentId)
            agent = a
            terr = e
            // 0.1.71（TS-118）：suggested_role 兜底搜索——弱模型常把角色名填进
            // suggested_role 而 target 写错/写别名；新建前先搜一轮，命中即复用
            if agent == nil && !roleArg.isEmpty && roleArg != targetArg {
                let (a2, _) = Self.resolveTarget(db: db, projectId: projectId,
                                                 target: roleArg, selfAgentId: agentId)
                agent = a2
            }
            if agent == nil {
                // TS-108 决策 9：目标不存在 → 按开关决定自动新建或转述用户。
                // H14：弱模型常不填 suggested_role → 缺省时用目标名兜底新建。
                if configBool("auto_create_sub_agents", true) {
                    // 0.4.9（3.47.2）：指定了 model → 用该模型新建；未指定 → 沿用主 Agent 模型
                    agent = Self.autoCreateAgent(
                        db: db, projectId: projectId,
                        suggestedRole: roleArg.isEmpty ? targetArg : roleArg,
                        modelName: !modelArg.isEmpty ? modelArg
                            : (!parentModel.isEmpty ? parentModel : "qwen3.8"))
                    autoCreated = true
                } else {
                    result = NativeAgentLoop.err(
                        terr + "（自动新建子 Agent 功能已关闭。请告知用户：可在设置面板"
                        + "“多 Agent”区开启，或先在 Agent 面板手动创建子 Agent 后再委派。）")
                }
            }
        }

        if let agent {
            // TS-117：合并聊天附着图 + image_paths 加载图（first_round_images 通道每轮重发）
            let delegImages = (firstRoundImages ?? []) + loadedImages
            // 0.4.9（3.47.2）：本次委派实际使用的子模型
            let childModel = !modelArg.isEmpty ? modelArg : (agent.modelName ?? "")
            // 0.4.9（3.47.3）委派模型换装编排（防护③：并行场景不卸载）
            let swapEnabled = configBool("delegation_model_swap", true)
                && !configBool("task_concurrency", false)
                && !configBool("model_parallel", false)
            if swapEnabled && !parentModel.isEmpty && !childModel.isEmpty
                && parentModel != childModel {
                _ = await safeUnloadModel?(parentModel)   // 委派前：腾出内存给子模型
            }
            let req = NativeDelegationTaskRequest(
                projectId: projectId, parentAgentId: agentId, parentSessionId: sessionId,
                targetAgent: agent, task: taskArg, expect: expectArg,
                sandboxRoot: sandboxRoot, maxRounds: maxRounds,
                images: delegImages.isEmpty ? nil : delegImages,
                filePaths: resolvedFiles.isEmpty ? nil : resolvedFiles,
                simpleMode: (args["simple_mode"]?.bool ?? false) ? true : nil,
                modelOverride: modelArg.isEmpty ? nil : modelArg)
            // 测试接缝存在时走打桩（对齐 Python patch delegation.run_delegated_task）
            var res: [String: JSONValue]
            if let coreOverride {
                res = await coreOverride(req)
            } else {
                res = try await runDelegatedTask(req)
            }
            // 0.4.9（3.47.3）：交卷后卸子模型（失败/超时/中断路径都清理）
            if swapEnabled && !childModel.isEmpty {
                _ = await safeUnloadModel?(childModel)
            }
            // TS-108：自动新建场景标注新 Agent，供主 Agent 告知用户
            if autoCreated { res["created_agent"] = .string(agent.name) }
            // TS-117：报告图片加载结果（loaded / skipped）
            if !loadedImages.isEmpty || !skippedPaths.isEmpty {
                res["images_loaded"] = .int(Int64((firstRoundImages ?? []).count + loadedImages.count))
                if !skippedPaths.isEmpty {
                    res["images_skipped"] = .array(skippedPaths.map { .string($0) })
                }
            }
            // #15：同样报告文档路径解析结果（静默丢失比报错更危险）
            if !resolvedFiles.isEmpty || !skippedFiles.isEmpty {
                res["files_passed"] = .int(Int64(resolvedFiles.count))
                if !skippedFiles.isEmpty {
                    res["files_skipped"] = .array(skippedFiles.map { .string($0) })
                }
            }
            return res
        }
        return result
    }
}

/// 锁内泛型盒子（engine 测试接缝的可变状态；@unchecked Sendable 语义同 NativeDatabase）。
final class NativeLockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ v: T) { value = v }
    func withLock<R>(_ f: (inout T) -> R) -> R {
        lock.lock(); defer { lock.unlock() }
        return f(&value)
    }
}
