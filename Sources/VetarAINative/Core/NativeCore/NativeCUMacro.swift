//
//  NativeCUMacro.swift
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

//  逐行为移植 subagent/sidecar/computer_use/cu_macro.py（⛔ 只读行为规格源，542 行；
//  语义分歧以 Python 源码为准）：
//    · 存储：{data_root}/cu_macros/<macro_id>.json，tmp + rename 原子写
//      （写一半被 kill 不得留下半截文件）；id 合法性防路径穿越
//    · 录制器（进程级单例语义——每 NativeComputerUseEngine 持一实例）：
//      agent 模式录制【Agent 自己经 CU 工具发起的动作序列】（executor 成功后挂钩落步，
//      失败动作不落宏）；step = {seq, action, x, y, app, element, payload, ts}，
//      title ≤80 / role ≤40 截断防御
//    · 空宏防护（0.4.33 F2）：stop 时 steps==0 → 不落盘，返回
//      {ok, saved:false, steps:0, message:"未捕获到任何动作，宏未保存"}
//    · 回放 = 逐步 element 语义重放：click 类按 step.app + element.role/title 经
//      appElements(depth≤2) 找匹配元素 → 点 frame 中心（窗口挪位仍命中）；
//      匹配不到回落 step 原像素坐标；type/key 直接重放 payload
//    · R4 中止：目标 app 未运行/无窗口 → 该步错误并【中止】报步骤号
//      （不做跳过策略——静默跳过会把后续点击打到错误界面，比中止更危险）
//    · 真实键鼠独占：_REPLAY_BUSY 守卫，忙时 replay_busy；0 步空宏拒绝回放
//      （empty_macro——静默完成等于假成功）；RUNS_KEPT=50 内存运行记录上限
//    · 回放异步（后台任务逐步执行，start_replay 立即返回 run_id）——
//      端点不能同步等回放（回放是秒级真实键鼠操作）
//
//  P3-W4 补齐（原 W4c 砍项落地）：user 模式系统级录制（0.4.34 R4，
//  user_recorder.py → NativeUserRecorder.swift）：
//    · start_recording(name, mode) 双模式（L218-270 逐行为）：agent 缺省零变化；
//      user 三道闸——未授予「输入监控」→ input_monitoring_not_granted（端点 403，
//      含中文指引 + 本进程二进制路径）；回放进行中 → replay_busy conflict（409）；
//      跨模式同时录 → already_recording conflict=True（409，agent+agent 保持 422）
//    · recording_mode()（L186-189 契约字段）+ stop 顺序铁律（L320-322：
//      先拆捕获 flush 收尾步骤，再清 _REC 落盘——顺序反了宏丢尾巴）
//    · start_replay 互斥（L378-385）：user 录制中回放 → user_recording_busy（409）
//    · delete_macro（L156-167，原 W4c ⚠️VERIFY 项）：id 非法/不存在 → false（404）
//    · _push_step_event（L428-442）：回放每步事件经注入缝上原生总线
//      （W4c 未推 SSE 的 ⚠️VERIFY 项本波闭环）
//    · TCC 主体重归属：原生 app 可执行文件（Bundle.main.executablePath），
//      引导文案逐字对齐 Python
//

import Foundation

public final class NativeCUMacroStore: @unchecked Sendable {

    // ── 协议常量（cu_macro.py L58-66，非用户可配）──
    public static let titleMax = 80               // TITLE_MAX（element.title 落盘截断防爆）
    public static let roleMax = 40                // ROLE_MAX
    public static let replayStepInterval = 0.3    // REPLAY_STEP_INTERVAL（测试可置 0）
    public static let runsKept = 50               // RUNS_KEPT（回放运行记录内存保留上限）
    /// _CLICK_MAP（回放动作名 → (button, clicks)）。
    public static let clickMap: [String: (String, Int)] = [
        "click": ("left", 1), "double_click": ("left", 2), "right_click": ("right", 1),
    ]
    /// _APP_MISSING_KEYS（app_elements 失败原因中出现这些子串 = app 未运行/无窗口）。
    public static let appMissingKeys = ["app_not_found", "无窗口"]

    /// step 的 element 语义（{"role","title","frame"}）。
    public struct StepElement: Sendable, Equatable {
        public var role: String
        public var title: String
        public var frame: [Double]?
        public init(role: String, title: String, frame: [Double]?) {
            self.role = role
            self.title = title
            self.frame = frame
        }
    }

    /// 宏摘要（cu_macro_list 行：id/name/created_at/steps 数）。
    public struct MacroSummary: Sendable {
        public var id: String
        public var name: String
        public var createdAt: String
        public var steps: Int
        public var asJSON: JSONValue {
            .object(["id": .string(id), "name": .string(name),
                     "created_at": .string(createdAt), "steps": .int(Int64(steps))])
        }
    }

    /// 回放运行记录（_RUNS 行同构）。
    public struct ReplayRun: Sendable {
        public var runId: String
        public var macroId: String
        public var macroName: String
        public var status: String            // running | done | error
        public var startedAt: String
        public var finishedAt: String
        public var total: Int
        public var completed: Int
        public var failedSeq: Int?
        public var error: String
        public var steps: [[String: JSONValue]]
    }

    private let macrosDir: URL
    private let sleeper: @Sendable (Double) -> Void
    /// 执行面（回放驱动与 executor 同源的动作链；由引擎在 init 后回接）。
    /// 参数：(x, y, button, clicks) / (text) / (keys) → 结果字典（{"ok":...}）。
    var clickExecutor: ((Double, Double, String, Int) -> [String: JSONValue])?
    var typeExecutor: ((String) -> [String: JSONValue])?
    var hotkeyExecutor: ((String) -> [String: JSONValue])?
    var elementsProvider: ((String, Int) -> [NativeCUElementHit])?   // appElements(app, depth)
    var axLastErrorProvider: (() -> String)?

    // ── P3-W4：user 模式（系统级录制）与回放步骤事件注入缝
    //   （生产由 kernel 的 cuMacroEndpoints 装配；测试注入假探针，绝不触真 TCC/键鼠）──
    /// 「输入监控」TCC 状态（user_recorder.listen_access_granted 同构；nil = 探测不到）。
    public var listenAccessGrantedProvider: (() -> Bool?)?
    /// cu_user_record_max_seconds 读取（config；读不到/0 → 600，Python `or 600` 口径）。
    public var maxSecondsProvider: (() -> Double)?
    /// user_recorder.start_capture 同构工厂：(onStep, onTimeout, maxSeconds) → 捕获会话；
    /// 返回 nil = 启动失败（tap 创建失败/已在捕获——capture_failed 契约）。
    public var userCaptureFactory: ((@escaping @Sendable (NativeUserRecorder.Step) -> Void,
                                     @escaping @Sendable () -> Void, Double)
                                    -> (any NativeUserCaptureSession)?)?
    /// _push_step_event 同构：(run_id, macro_id, seq, step_action, method, ok)。
    public var replayStepEventPusher: ((String, String, Int, String, String, Bool) -> Void)?
    /// executor._process_identity()["exe"] 同构：TCC 引导文案的二进制路径
    /// （TCC 按二进制授权；原生侧主体 = 原生 app 可执行文件）。
    public var processExeProvider: () -> String = { Bundle.main.executablePath ?? "" }

    // ── 录制器状态（_REC 同构；0.4.34 R4 双模式）──
    /// 引用语义：stopRecording 的「_REC is rec」身份比对需要（cap.stop() flush 期间
    /// 若被新录制顶替，不得误清）。
    private final class Recording {
        let name: String
        let startedAt: String
        var steps: [[String: JSONValue]]
        let mode: String                                // "agent" | "user"
        let capture: (any NativeUserCaptureSession)?    // user 模式的系统级捕获会话
        init(name: String, startedAt: String, mode: String,
             capture: (any NativeUserCaptureSession)?) {
            self.name = name
            self.startedAt = startedAt
            self.steps = []
            self.mode = mode
            self.capture = capture
        }
    }
    private var rec: Recording?
    /// RLock 同构（Python _REC_LOCK = threading.RLock）：startRecording 持锁调
    /// userCaptureFactory，捕获若同步吐 step（recordStep 重入）不得死锁。
    private let recLock = NSRecursiveLock()

    // ── 回放状态（_RUNS / _REPLAY_BUSY 同构）──
    private var runs: [String: ReplayRun] = [:]
    private var runOrder: [String] = []   // 插入序（RUNS_KEPT 挤最旧）
    private var replayBusy = false
    private let runLock = NSLock()

    public init(dataRoot: URL,
                sleeper: (@Sendable (Double) -> Void)? = nil) {
        let dir = dataRoot.appendingPathComponent("cu_macros", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.macrosDir = dir
        self.sleeper = sleeper ?? { seconds in
            if seconds > 0 { Thread.sleep(forTimeInterval: seconds) }
        }
    }

    static func err(_ message: String) -> [String: JSONValue] {
        ["ok": .bool(false), "error": .string(message)]
    }

    private static func now() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"   // isoformat(timespec="seconds")
        return fmt.string(from: Date())
    }

    // ══════════════════════════════════════════════════════════
    // MARK: id 与存储（valid_macro_id / save / load / list 逐行为）
    // ══════════════════════════════════════════════════════════

    /// _slug：名称 → id 用 slug（小写字母/数字/-；非 [a-z0-9] 折叠为 -，空则 macro）。
    static func slug(_ name: String) -> String {
        let lowered = name.lowercased()
        var s = lowered.replacingOccurrences(of: #"[^a-z0-9]+"#, with: "-",
                                             options: .regularExpression)
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return String((s.isEmpty ? "macro" : s).prefix(24))
    }

    /// _new_macro_id：时间戳 + 名称 slug + uuid 短后缀。
    static func newMacroId(_ name: String) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd-HHmmss"
        let short = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(4))
        return "cu-\(fmt.string(from: Date()))-\(slug(name))-\(short)"
    }

    /// valid_macro_id：^[A-Za-z0-9][A-Za-z0-9_-]{0,79}$（防路径穿越）。
    public static func validMacroId(_ macroId: String) -> Bool {
        macroId.range(of: #"^[A-Za-z0-9][A-Za-z0-9_-]{0,79}$"#,
                      options: .regularExpression) != nil
    }

    private func macroPath(_ macroId: String) -> URL? {
        guard Self.validMacroId(macroId) else { return nil }
        return macrosDir.appendingPathComponent("\(macroId).json")
    }

    /// save_macro：tmp + rename 原子写；失败抛异常（调用方转 ok:False，绝不静默丢宏）。
    func saveMacro(_ macro: [String: JSONValue]) throws {
        let id = macro["id"]?.string ?? ""
        let path = macrosDir.appendingPathComponent("\(id).json")
        let tmp = macrosDir.appendingPathComponent("\(id).json.tmp")
        // json.dumps(indent=2)：原生紧凑写出（内容等价，缩进不逐字——文件为内部格式）
        let data = NativeDatabase.dumpsUTF8(.object(macro)).data(using: .utf8) ?? Data()
        try data.write(to: tmp)
        _ = try? FileManager.default.removeItem(at: path)
        try FileManager.default.moveItem(at: tmp, to: path)
    }

    /// load_macro：id 非法 / 文件缺失 / JSON 损坏 / steps 非数组 → nil。
    public func loadMacro(_ macroId: String) -> [String: JSONValue]? {
        guard let path = macroPath(macroId),
              FileManager.default.fileExists(atPath: path.path),
              let data = try? Data(contentsOf: path),
              case .object(let obj)? = NativeJSONWriter.loads(data),
              case .array = obj["steps"] else { return nil }
        return obj
    }

    /// list_macros：摘要列表（损坏文件跳过；按 (created_at, id) 排序）。
    public func listMacros() -> [MacroSummary] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: macrosDir, includingPropertiesForKeys: nil) else { return [] }
        var out: [MacroSummary] = []
        for f in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where f.pathExtension == "json" {
            guard let data = try? Data(contentsOf: f),
                  case .object(let obj)? = NativeJSONWriter.loads(data) else { continue }
            let steps: Int = {
                if case .array(let s)? = obj["steps"] { return s.count }
                return 0
            }()
            out.append(MacroSummary(
                id: obj["id"]?.string ?? f.deletingPathExtension().lastPathComponent,
                name: obj["name"]?.string ?? "",
                createdAt: obj["created_at"]?.string ?? "",
                steps: steps))
        }
        out.sort { a, b in
            a.createdAt != b.createdAt ? a.createdAt < b.createdAt : a.id < b.id
        }
        return out
    }

    // ══════════════════════════════════════════════════════════
    // MARK: 录制（start_recording / record_step / stop_recording 逐行为；agent 模式）
    // ══════════════════════════════════════════════════════════

    public func isRecording() -> Bool {
        recLock.lock(); defer { recLock.unlock() }
        return rec != nil
    }

    /// recording_steps（0.4.33 F2：列表端点轮询带出）。
    public func recordingSteps() -> Int {
        recLock.lock(); defer { recLock.unlock() }
        return rec?.steps.count ?? 0
    }

    /// recording_mode（0.4.34 R4 契约字段，L186-189）：nil（未录制）| "agent" | "user"。
    public func recordingMode() -> String? {
        recLock.lock(); defer { recLock.unlock() }
        return rec?.mode
    }

    /// _input_monitoring_error（L199-215 逐字）：契约5——user 模式未授权的统一报错
    /// （端点映射 403；detail 含中文授权指引 + 本进程二进制路径——TCC 按二进制授权，
    /// P3-W4 重归属后主体 = 原生 app 可执行文件）。
    private func inputMonitoringError() -> [String: JSONValue] {
        let exe = processExeProvider()
        let guide = exe.isEmpty ? "" : "请把这个文件本身加入名单：\n    \(exe)\n"
        return Self.err(
            "input_monitoring_not_granted: 「输入监控」权限未授予，系统级录制会被系统拒绝"
            + "（CGEventTapCreate 直接返回空）。它与「辅助功能」是两项独立授权，"
            + "已授权辅助功能不覆盖输入监控。\n"
            + guide
            + "操作：系统设置→隐私与安全性→输入监控 → 点「+」→ 按 Cmd+Shift+G 粘贴上述路径 "
            + "→ 添加并勾选 → 完全退出 VetarAI（Cmd+Q）后重开（权限在进程启动时读取）。")
    }

    /// start_recording(name, mode)（L218-270 逐行为）：已在录制 / 名称为空 / mode 非法
    /// → ok:False（端点按 422/409/403 映射）。
    /// mode="agent"（默认）：三期原行为零变化（agent+agent 重复开始 → conflict=False）。
    /// mode="user"（0.4.34 R4）：未授予「输入监控」→ input_monitoring_not_granted（403）；
    /// 回放进行中 → replay_busy conflict（409）；涉 user 的同时录 → conflict=True（409）。
    public func startRecording(name: String, mode: String = "agent") -> [String: JSONValue] {
        let nm = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if nm.isEmpty {
            return Self.err("bad_arg: 宏名称不能为空")
        }
        let md = mode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard md == "agent" || md == "user" else {
            return Self.err("bad_arg: mode 只能是 agent/user（收到 \(PySem.reprString(mode))）")
        }
        recLock.lock()
        defer { recLock.unlock() }
        if let cur = rec {
            return ["ok": .bool(false),
                    "error": .string("already_recording: 正在录制宏「\(cur.name)」（\(cur.mode) 模式），"
                        + "请先停止当前录制"),
                    // agent+agent → conflict=False（端点 422 原状）；涉 user → True（409）
                    "conflict": .bool(md == "user" || cur.mode == "user")]
        }
        var capture: (any NativeUserCaptureSession)?
        if md == "user" {
            // ⛔ user 模式未授权必须拒绝（403 契约；真实 tap 无权限必建空）
            if listenAccessGrantedProvider?() == false {
                return inputMonitoringError()
            }
            runLock.lock()
            let busy = replayBusy
            runLock.unlock()
            if busy {
                return ["ok": .bool(false),
                        "error": .string("replay_busy: 已有回放进行中（真实键鼠是独占资源，回放的合成事件"
                            + "会被系统级捕获录进宏造成污染），请等当前回放完成再开始录制"),
                        "conflict": .bool(true)]
            }
            var maxS = maxSecondsProvider?() ?? 600
            if maxS == 0 { maxS = 600 }        // Python `or 600` 口径（0 视为未配）
            capture = userCaptureFactory?({ [weak self] step in
                self?.recordStep(step)
            }, { [weak self] in
                self?.autoStopTimeout()
            }, maxS)
            guard capture != nil else {
                return Self.err("capture_failed: 系统级捕获启动失败（CGEventTap 创建失败或已在捕获）。"
                    + "请确认「输入监控」已授予且没有其他录制在进行")
            }
        }
        rec = Recording(name: String(nm.prefix(Self.titleMax)), startedAt: Self.now(),
                        mode: md, capture: md == "user" ? capture : nil)
        return ["ok": .bool(true), "name": .string(rec!.name), "mode": .string(md)]
    }

    /// _auto_stop_timeout（L273-278）：硬上限到点（ticker 线程触发）——视作正常 stop。
    private func autoStopTimeout() {
        _ = stopRecording()
    }

    /// record_step：executor 挂钩追加一步。⛔ 绝不抛异常——录制是旁路，
    /// 绝不能搞挂动作本身（与 audit 同级防线语义）。title≤80 / role≤40 截断防御。
    @discardableResult
    public func recordStep(action: String, x: Double?, y: Double?, app: String,
                           element: StepElement?, payload: [String: JSONValue]) -> Bool {
        recLock.lock()
        defer { recLock.unlock() }
        guard rec != nil else { return false }
        var step: [String: JSONValue] = [
            "seq": .int(Int64(rec!.steps.count + 1)),
            "action": .string(action),
            "x": x.map { .double($0) } ?? .null,
            "y": y.map { .double($0) } ?? .null,
            "app": .string(app),
            "payload": .object(payload),
            "ts": .string(Self.now()),
        ]
        if let element {
            step["element"] = .object([
                "role": .string(String(element.role.prefix(Self.roleMax))),
                "title": .string(String(element.title.prefix(Self.titleMax))),
                "frame": element.frame.map { .array($0.map { .double($0) }) } ?? .null,
            ])
        } else {
            step["element"] = .null
        }
        rec!.steps.append(step)
        return true
    }

    /// record_step 的 recorder Step 入口（P3-W4：user 模式 onStep 回调；
    /// 底层仍走同一 recordStep 字典入口，seq/ts/截断防御单一事实源）。
    @discardableResult
    public func recordStep(_ step: NativeUserRecorder.Step) -> Bool {
        let el = step.element.map {
            StepElement(role: $0.role, title: $0.title, frame: $0.frame)
        }
        return recordStep(action: step.action, x: step.x, y: step.y, app: step.app,
                          element: el, payload: step.payload)
    }

    /// stop_recording（L315-349 逐行为）：steps>0 → 落盘返回 {ok, saved:true, macro}；
    /// 未在录制 → ok:False；0 步 → 【不落盘】（0.4.33 F2 空宏防护）。
    /// 0.4.34 R4 顺序铁律：user 模式先拆系统级捕获（cap.stop() flush 的最终聚合
    /// 步骤此刻 rec 仍在、recordStep 受理），再清 rec 落盘——顺序反了宏丢尾巴。
    public func stopRecording() -> [String: JSONValue] {
        recLock.lock()
        guard let cur = rec else {
            recLock.unlock()
            return Self.err("not_recording: 当前没有进行中的录制")
        }
        recLock.unlock()
        cur.capture?.stop()                      // 干净拆除 + flush 收尾步骤（rec 仍在）
        recLock.lock()
        if rec === cur { rec = nil }             // 「_REC is rec」身份比对（防顶替误清）
        recLock.unlock()
        if cur.steps.isEmpty {
            // ⛔ 0 步宏不得落盘
            return ["ok": .bool(true), "saved": .bool(false), "steps": .int(0),
                    "message": .string("未捕获到任何动作，宏未保存")]
        }
        let macro: [String: JSONValue] = [
            "id": .string(Self.newMacroId(cur.name)),
            "name": .string(cur.name),
            "created_at": .string(cur.startedAt),
            "steps": .array(cur.steps.map { .object($0) }),
        ]
        do {
            try saveMacro(macro)
        } catch {
            return Self.err("save_failed: 宏落盘失败（\(type(of: error)): \(error)）")
        }
        return ["ok": .bool(true), "saved": .bool(true), "macro": .object(macro)]
    }

    /// delete_macro（L156-167 逐行为）：id 非法 / 不存在 → false（端点按 404）。
    /// （原 W4c ⚠️VERIFY 砍项，P3-W4 随端点面一并落地。）
    public func deleteMacro(_ macroId: String) -> Bool {
        guard let path = macroPath(macroId) else { return false }
        do {
            try FileManager.default.removeItem(at: path)
            return true
        } catch {
            return false                         // FileNotFoundError / 其他异常 → False 同口径
        }
    }

    // ══════════════════════════════════════════════════════════
    // MARK: 回放（start_replay / run_replay / _relocate / _abort 逐行为）
    // ══════════════════════════════════════════════════════════

    /// get_run（回放状态查询；P3-W4 起步骤事件经 replayStepEventPusher 上原生总线）。
    public func getRun(_ runId: String) -> ReplayRun? {
        runLock.lock(); defer { runLock.unlock() }
        return runs[runId]
    }

    /// 宏回放审计聚合行（0.7.4 W5：命中率「全程审计」口径，只读）。
    public struct MacroAuditEntry: Sendable, Equatable {
        public var macroId: String
        public var macroName: String
        public var replays: Int          // 内存运行记录里的回放次数
        public var successes: Int        // status == "done" 的回放次数
        public var elementHits: Int      // 各 run 全部步骤中 method=="element" 的步数
        public var pixelFallbacks: Int   // 各 run 全部步骤中 method=="pixel_fallback" 的步数
    }

    /// 全程审计聚合（0.7.4 W5）：遍历内存运行记录（runs / runOrder 插入序），
    /// 按 macroId 聚合回放次数 / 成功次数 / 元素命中 / 像素回落。
    /// ⚠️ 口径：进程内内存记录——重启即空，且只保留最近 RUNS_KEPT=50 条 run；
    /// 这是「当前进程内全程」口径，不是持久历史（持久审计见 actions.jsonl）。
    public func macroAuditSummary() -> [MacroAuditEntry] {
        runLock.lock(); defer { runLock.unlock() }
        var agg: [String: MacroAuditEntry] = [:]
        var order: [String] = []
        for runId in runOrder {
            guard let run = runs[runId] else { continue }
            if agg[run.macroId] == nil {
                agg[run.macroId] = MacroAuditEntry(
                    macroId: run.macroId, macroName: run.macroName,
                    replays: 0, successes: 0, elementHits: 0, pixelFallbacks: 0)
                order.append(run.macroId)
            }
            var e = agg[run.macroId]!
            e.replays += 1
            if run.status == "done" { e.successes += 1 }
            for s in run.steps {
                switch s["method"]?.string {
                case "element": e.elementHits += 1
                case "pixel_fallback": e.pixelFallbacks += 1
                default: break       // payload/abort 等不计入命中率分子分母
                }
            }
            agg[run.macroId] = e
        }
        return order.compactMap { agg[$0] }
    }

    /// start_replay：校验宏存在 → 登记 run → 后台任务回放，立即返回 run_id。
    /// 0 步宏拒绝（empty_macro）；真实键鼠独占守卫（replay_busy）。
    public func startReplay(macroId: String) -> [String: JSONValue] {
        guard Self.validMacroId(macroId), let macro = loadMacro(macroId) else {
            return Self.err("not_found")
        }
        guard case .array(let steps)? = macro["steps"], !steps.isEmpty else {
            // ⛔ 0 步宏不得回放（静默完成等于假成功）
            return Self.err("empty_macro: 宏没有可回放的步骤")
        }
        recLock.lock()
        let userRec = rec != nil && rec!.mode == "user"
        recLock.unlock()
        if userRec {
            // ⛔ user 录制中必须拒绝回放（0.4.34 R4 互斥契约6：回放的合成事件
            //    会被系统级 tap 录进宏造成污染，真实键鼠是独占资源）
            return ["ok": .bool(false),
                    "error": .string("user_recording_busy: 正在录制用户操作宏（系统级捕获中），"
                        + "回放的真实键鼠事件会被录进宏造成污染。请先停止录制再回放"),
                    "conflict": .bool(true)]
        }
        runLock.lock()
        if replayBusy {
            runLock.unlock()
            return Self.err("replay_busy: 已有回放进行中（真实键鼠是独占资源，"
                + "并发回放会互相踩坐标），请等当前回放完成")
        }
        replayBusy = true
        let runId = "run-\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12))"
        let run = ReplayRun(
            runId: runId,
            macroId: macro["id"]?.string ?? macroId,
            macroName: macro["name"]?.string ?? "",
            status: "running", startedAt: Self.now(), finishedAt: "",
            total: steps.count, completed: 0,
            failedSeq: nil, error: "", steps: [])
        runs[runId] = run
        runOrder.append(runId)
        while runOrder.count > Self.runsKept {      // 上限保护：挤掉最旧记录
            let oldest = runOrder.removeFirst()
            runs.removeValue(forKey: oldest)
        }
        runLock.unlock()

        // 后台任务回放（对齐 daemon thread；⛔ 不能同步等回放——秒级真实键鼠）
        Task.detached { [weak self] in
            guard let self else { return }
            defer { self.clearReplayBusy() }
            self.runReplay(runId: runId, macro: macro)
        }
        return ["ok": .bool(true), "run_id": .string(runId)]
    }

    /// 同步小助手：在同步上下文内持锁复位 busy（避开异步上下文直调 NSLock）。
    private func clearReplayBusy() {
        runLock.lock()
        replayBusy = false
        runLock.unlock()
    }

    /// _step_finish：登记一步结果 + 推事件（成功与失败同路径，保证事件序列完整；
    /// P3-W4：_push_step_event 经注入缝上原生总线——run_id/macro_id/seq/
    /// step_action/method/ok 六字段逐字，⛔ 绝不抛异常=非 throwing 类型保证）。
    private func stepFinish(_ runId: String, seq: Int, action: String,
                            method: String, ok: Bool, error: String = "") {
        runLock.lock()
        guard var run = runs[runId] else {
            runLock.unlock()
            return
        }
        run.steps.append(["seq": .int(Int64(seq)), "action": .string(action),
                          "method": .string(method), "ok": .bool(ok),
                          "error": .string(error)])
        if ok { run.completed += 1 }
        runs[runId] = run
        let macroId = run.macroId
        runLock.unlock()
        replayStepEventPusher?(runId, macroId, seq, action, method, ok)
    }

    /// _abort（R4 拍板【默认中止】）：登记失败步、报步骤号、不再执行后续步骤。
    private func abort(_ runId: String, seq: Int, action: String,
                       method: String, reason: String) {
        stepFinish(runId, seq: seq, action: action, method: method,
                   ok: false, error: String(reason.prefix(200)))
        runLock.lock()
        defer { runLock.unlock() }
        guard var run = runs[runId] else { return }
        run.status = "error"
        run.failedSeq = seq
        run.error = "第 \(seq) 步（\(action)）失败：\(reason)。已中止，后续步骤未执行。"
        run.finishedAt = Self.now()
        runs[runId] = run
    }

    /// _relocate：click 类步骤的语义重定位。返回 (method, x, y, err)：
    ///   "element" 命中 role+title 一致元素 → frame 中心（窗口挪位仍命中）；
    ///   "pixel_fallback" 录制时本无元素语义/枚举失败/匹配不到 → step 原像素坐标；
    ///   "abort" 目标 app 未运行/窗口未开（R4：该步错误并中止）。
    private func relocate(_ step: [String: JSONValue]) -> (String, Double?, Double?, String) {
        let ox = step["x"]?.double ?? step["x"]?.int.map { Double($0) }
        let oy = step["y"]?.double ?? step["y"]?.int.map { Double($0) }
        guard case .object(let el)? = step["element"] else {
            return ("pixel_fallback", ox, oy, "")   // 录制时未命中元素，只能按像素重放
        }
        let app = step["app"]?.string ?? ""
        if app.isEmpty {
            return ("pixel_fallback", ox, oy, "")
        }
        let els = elementsProvider?(app, 2) ?? []
        if els.isEmpty {
            let err = axLastErrorProvider?() ?? ""
            if Self.appMissingKeys.contains(where: { err.contains($0) }) {
                // ⛔ app 未运行/无窗口必须中止（R4），不得回落像素乱点
                return ("abort", nil, nil, "目标应用「\(app)」未运行或没有窗口（\(err)）")
            }
            // ⛔ 枚举失败（权限/超时等）回落像素，不阻断回放
            return ("pixel_fallback", ox, oy, "")
        }
        let role = el["role"]?.string ?? ""
        let title = el["title"]?.string ?? ""
        var cand = els.filter { ($0.role ?? "") == role }
        if !title.isEmpty {
            // ⛔ title 必须参与匹配（同 role 多元素时靠 title 区分，否则点错按钮）
            cand = cand.filter { ($0.title ?? "") == title }
        }
        for e in cand {
            if let fr = e.frame, fr.2 > 0, fr.3 > 0 {
                return ("element", fr.0 + fr.2 / 2.0, fr.1 + fr.3 / 2.0, "")
            }
        }
        // ⛔ 匹配不到回落 step 原像素坐标（计划 E4 既定回落路径）
        return ("pixel_fallback", ox, oy, "")
    }

    /// run_replay 同步核心（start_replay 的后台任务与测试都调它）。
    /// 逐步执行：click 类语义重定位 → executor 现有动作链（含二期校正）；
    /// type/key 类直接重放 payload。任一步失败即 _abort 中止（报步骤号）。
    @discardableResult
    public func runReplay(runId: String, macro: [String: JSONValue]) -> ReplayRun? {
        guard case .array(let steps)? = macro["steps"] else { return nil }
        runLock.lock()
        if var run = runs[runId] {
            run.total = steps.count
            runs[runId] = run
        }
        runLock.unlock()

        for st in steps {
            guard case .object(let step) = st else { continue }
            let seq = Int(step["seq"]?.int ?? step["seq"]?.double.map { Int64($0) } ?? 0)
            let action = step["action"]?.string ?? ""
            var method = ""
            var result: [String: JSONValue]
            if let (btn, n) = Self.clickMap[action] {
                let (m, x, y, err) = relocate(step)
                method = m
                if m == "abort" {
                    abort(runId, seq: seq, action: action, method: m, reason: err)
                    return getRun(runId)
                }
                guard let x, let y, let clickExecutor else {
                    abort(runId, seq: seq, action: action, method: m,
                          reason: "bad_arg: 坐标必须是数字（收到 x=\(String(describing: step["x"])), y=\(String(describing: step["y"])))")
                    return getRun(runId)
                }
                result = clickExecutor(x, y, btn, n)
            } else if action == "type" {
                method = "payload"
                let text = step["payload"]?.object?["text"]?.string ?? ""
                result = typeExecutor?(text) ?? Self.err("type 执行面未装配")
            } else if action == "key" {
                method = "payload"
                let keys = step["payload"]?.object?["keys"]?.string ?? ""
                result = hotkeyExecutor?(keys) ?? Self.err("hotkey 执行面未装配")
            } else {
                abort(runId, seq: seq, action: action.isEmpty ? "?" : action, method: "",
                      reason: "unknown_action: 不认识的宏动作 '\(action)'（宏文件可能损坏）")
                return getRun(runId)
            }
            if result["ok"] != .bool(true) {
                abort(runId, seq: seq, action: action, method: method,
                      reason: result["error"]?.string ?? "动作执行失败")
                return getRun(runId)
            }
            stepFinish(runId, seq: seq, action: action, method: method, ok: true)
            sleeper(Self.replayStepInterval)
        }
        runLock.lock()
        defer { runLock.unlock() }
        guard var run = runs[runId] else { return nil }
        run.status = "done"
        run.finishedAt = Self.now()
        runs[runId] = run
        return run
    }
}
