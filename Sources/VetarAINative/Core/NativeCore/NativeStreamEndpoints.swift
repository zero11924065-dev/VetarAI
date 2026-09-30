//
//  NativeStreamEndpoints.swift
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

//  逐行为移植（⛔ 只读行为规格源：subagent/sidecar/app.py）：
//    · api_stream_agent_tasks（L1653-1713）：snapshot 权威基线（DB limit=50）→
//      subscribe 实时增量；_subscribed/_idle 不下发（_idle  Python 转 `: keepalive`
//      注释行——进程内直通无消费方，同 NativeChatEndpoints 偏差①，仅作唤醒源跳过）；
//      _channel_closed → stream_end{reason: channel_closed}；payload 补 task_id/seq。
//    · api_stream_app_events（L1716-1773）：connected 握手（带当前 seq）→ subscribe
//      实时增量；_bus_closed → stream_end{reason: bus_closed}；payload 补 seq。
//    · api_create_roundtable 附件预处理（L1861-1912）与附件落盘（L1919-1938）；
//      圆桌行 → 面板模型映射（store.py _rt_row_to_dict 同构）。
//    · A13 notify 端点级单点接入（_notify_change L982-997）：原生写路径双路径接线
//      的公共入口——NativeSidecarClient 写方法（用户路径）与 NativeAppModuleRegistry
//      写 handler（Agent 路径）各调一次，对齐 Python「端点成功 return 前 notify」。
//
//  偏差（汇报清单同步）：
//    ⑤ vision_parse_attachments 圆桌图片附件视觉识别 P3-W1b 已接管：
//       _vision_parse（app.py L1871-1885）逐行为——data URI 组装 → 固定 ollama
//       connector chat（config default_model 缺省 qwen3.8，prompt 逐字）→
//       ANY 失败空串仅标注（绝不阻塞创建）。
//    ⑥ 附件文本截断按 Swift unicodeScalars 计（Python len 按 code point——一致；
//       grapheme 簇（如 👨‍👩‍👧）计数不同，3000/12000 上限场景实际不可达）。
//    ⑦ events/stream 客户端方法 P3-W6 已翻转（偏差⑦收口）：plugins/CU宏/模型包
//       全量翻原生后其资源事件已由原生总线携带，NativeSidecarClient.appEventsStream
//       直返 NativeAppEventsEndpoint.stream，五个面板 VM 协议零改动。路由表已更新。
//

import Foundation

// MARK: - SSEEvent 产出助手（rawData 对齐 _sse_format 的 json.dumps 默认分隔）

@inline(__always)
func nativeStreamYield(_ continuation: AsyncThrowingStream<SSEEvent, Error>.Continuation,
                       _ event: String, _ data: [String: JSONValue]) {
    continuation.yield(SSEEvent(
        event: event,
        data: data.mapValues { $0.anyValue },
        rawData: NativeDatabase.dumpsUTF8(.object(data))))
}

// ════════════════════════════════════════════════════════════
// MARK: - api_stream_agent_tasks（委派任务实时进度 SSE）
// ════════════════════════════════════════════════════════════

public enum NativeTasksStreamEndpoint {

    /// AgentTaskRow → store.py list_agent_tasks 返回 dict 同构（snapshot tasks 元素）。
    static func taskJSON(_ r: NativeDatabase.AgentTaskRow) -> [String: JSONValue] {
        [
            "id": .string(r.id),
            "parent_agent_id": .string(r.parentAgentId),
            "parent_session_id": .string(r.parentSessionId),
            "target_agent_id": .string(r.targetAgentId),
            "target_agent_name": .string(r.targetAgentName),
            "task": .string(r.task),
            "expect": .string(r.expect),
            "status": .string(r.status),
            "report": r.report ?? .null,
            "fail_reason": r.failReason.map { .string($0) } ?? .null,
            "validation_failures": .int(Int64(r.validationFailures)),
            "session_id": r.sessionId.map { .string($0) } ?? .null,
            "created_at": r.createdAt.map { .string($0) } ?? .null,
            "updated_at": r.updatedAt.map { .string($0) } ?? .null,
        ]
    }

    /// GET /api/projects/{pid}/tasks/stream 等价（app.py L1677-1708 gen() 逐行为）。
    public static func stream(db: NativeDatabase, projectId: String, since: Int = 0)
        -> AsyncThrowingStream<SSEEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                // ① 权威基线：DB 当前任务列表（失败 → []，L1680-1683）
                let snap = (try? db.listAgentTasks(projectId: projectId, limit: 50)) ?? []
                nativeStreamYield(continuation, "snapshot",
                                  ["tasks": .array(snap.map { .object(taskJSON($0)) })])
                // ② 实时增量（subscribe 的 onTermination 归还订阅者计数，T9g 同构）
                for await ev in NativeDelegationEvents.subscribe(projectId, sinceSeq: since) {
                    if Task.isCancelled { break }
                    switch ev.event {
                    case "_subscribed", "_idle":
                        continue   // 内部控制事件不下发；_idle 心跳注释行无消费方（偏差①）
                    case "_channel_closed":
                        nativeStreamYield(continuation, "stream_end",
                                          ["reason": .string("channel_closed")])
                        continuation.finish()
                        return
                    default:
                        var payload = ev.data
                        payload["task_id"] = .string(ev.taskId)
                        payload["seq"] = .int(Int64(ev.seq))
                        nativeStreamYield(continuation, ev.event, payload)
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }
}

// ════════════════════════════════════════════════════════════
// MARK: - api_stream_app_events（A13 资源变更 SSE）
// ════════════════════════════════════════════════════════════

public enum NativeAppEventsEndpoint {

    /// GET /api/events/stream 等价（app.py L1741-1768 gen() 逐行为）。
    public static func stream(since: Int = 0) -> AsyncThrowingStream<SSEEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                // ① 握手基线：当前 seq（前端据此初始化游标）
                nativeStreamYield(continuation, "connected",
                                  ["seq": .int(Int64(NativeAppEvents.latestSeq()))])
                // ② 实时增量
                for await ev in NativeAppEvents.subscribe(sinceSeq: since) {
                    if Task.isCancelled { break }
                    switch ev.event {
                    case "_subscribed", "_idle":
                        continue
                    case "_bus_closed":
                        nativeStreamYield(continuation, "stream_end",
                                          ["reason": .string("bus_closed")])
                        continuation.finish()
                        return
                    default:
                        var payload = ev.data
                        payload["seq"] = .int(Int64(ev.seq))
                        nativeStreamYield(continuation, ev.event, payload)
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }
}

// ════════════════════════════════════════════════════════════
// MARK: - A13 notify 端点级单点接入（_notify_change L982-997）
// ════════════════════════════════════════════════════════════

public enum NativeEndpointNotify {
    /// _notify_change：绝不抛异常（旁路）；原生写路径双路径（用户/Agent）各调一次。
    @inline(__always)
    public static func change(_ resource: String, _ action: String,
                              projectId: String? = nil,
                              extra: [String: JSONValue] = [:]) {
        NativeAppEvents.notify(resource, action, projectId: projectId, extra: extra)
    }
}

// ════════════════════════════════════════════════════════════
// MARK: - _vision_parse（app.py L1871-1885，P3-W1b 接管：残余⑧）
// ════════════════════════════════════════════════════════════

/// _vision_parse 的连接器缝（get_ollama_connector().chat(model, messages, images=)
/// 等价；测试注入 stub）。生产实现 = NativeOllamaChatConnector.chat(model:messages:images:)。
public protocol NativeVisionChatConnector: Sendable {
    func chat(model: String, messages: [[String: JSONValue]], images: [String]) async throws -> String
}

extension NativeOllamaChatConnector: NativeVisionChatConnector {}

public enum NativeVisionProbe {

    /// prompt 逐字（app.py L1881）。
    public static let prompt = "请描述这张图片的关键内容，供讨论参考。"

    /// _vision_parse 逐行为：扩展名小写取末段（无点号 → "png"）组装 data URI →
    /// connector chat → result or ""。**ANY 失败 → 空串**（调用方仅标注，
    /// 绝不阻塞圆桌创建）。
    public static func describe(raw: Data, name: String,
                                connector: any NativeVisionChatConnector,
                                model: String) async -> String {
        do {
            let ext = NativeAttachmentEndpoints.extOf(name)   // 含 "."；无点号 → ""
            let suffix = ext.isEmpty ? "png" : String(ext.dropFirst())
            let dataURI = "data:image/\(suffix);base64," + raw.base64EncodedString()
            return try await connector.chat(model: model, messages: [
                ["role": .string("user"), "content": .string(prompt)],
            ], images: [dataURI])
        } catch {
            return ""
        }
    }
}

// ════════════════════════════════════════════════════════════
// MARK: - 圆桌端点面（api_*_roundtable 的附件预处理/落盘/行映射）
// ════════════════════════════════════════════════════════════

public enum NativeRoundtableEndpoints {

    // 附件限制（app.py L1844-1847 逐字）
    public static let attMaxCount = 5
    public static let attMaxBytes = 2 * 1024 * 1024
    public static let attMaxCharsEach = 3000
    public static let attMaxCharsTotal = 12000

    /// parse_attachment 的 kind 分类（parser.py L243-279 分支序逐字；文本提取归 NativeDocParser）。
    /// P3-W1b：实现收敛到 NativeAttachmentEndpoints.kindOf（附件端点同源共用）。
    static func kindOf(_ name: String) -> String {
        NativeAttachmentEndpoints.kindOf(name)
    }

    /// api_create_roundtable 附件预处理（L1861-1912）：
    /// 数量/base64/2MB 校验 → NativeDocParser 提取文本 → 图片且开关开 → _vision_parse
    /// （P3-W1b 接管，失败空串仅标注）→ 单件 3000 截断 → 总量 12000。
    /// 返回（注入纪要的 metas，待落盘的原始文件）。校验失败抛 400（原文案）。
    /// visionProbe=nil 等价 Python 开关关闭（image → 仅标注不注入）。
    public static func preprocessAttachments(
        _ inputs: [RTAttachmentInput],
        visionProbe: (@Sendable (Data, String) async -> String)? = nil) async throws
        -> (metas: [[String: JSONValue]], files: [(name: String, raw: Data)]) {
        guard !inputs.isEmpty else { return ([], []) }
        guard inputs.count <= attMaxCount else {
            throw SidecarError.httpError(status: 400, detail: "附件最多 \(attMaxCount) 个")
        }
        var metas: [[String: JSONValue]] = []
        var files: [(name: String, raw: Data)] = []
        for att in inputs {
            guard let raw = Data(base64Encoded: att.content_base64) else {
                throw SidecarError.httpError(status: 400, detail: "附件 \(att.name) 编码非法")
            }
            guard raw.count <= attMaxBytes else {
                throw SidecarError.httpError(status: 400, detail: "附件 \(att.name) 超过 2MB 限制")
            }
            files.append((att.name, raw))
            var text = NativeDocParser.parse(name: att.name, raw: raw)
            let kind = kindOf(att.name)
            // M7（TS-113）：图片且开关开 → 视觉识别（`or None` 口径：空串仍按无法解析标注）
            if text == nil, kind == "image", let visionProbe {
                let described = await visionProbe(raw, att.name)
                text = described.isEmpty ? nil : described
            }
            var truncated = false
            if let t = text, t.unicodeScalars.count > attMaxCharsEach {
                text = String(t.unicodeScalars.prefix(attMaxCharsEach))
                truncated = true
            }
            metas.append([
                "name": .string(att.name),
                "size": .int(Int64(raw.count)),
                "is_text": .bool(text != nil),
                "text": text.map { .string($0) } ?? .null,
                "kind": .string(kind),
                "truncated": .bool(truncated),
            ])
        }
        let totalChars = metas.reduce(0) { $0 + ($1["text"]?.string?.unicodeScalars.count ?? 0) }
        guard totalChars <= attMaxCharsTotal else {
            throw SidecarError.httpError(
                status: 400, detail: "附件文本总量超过 \(attMaxCharsTotal) 字，请精简材料")
        }
        return (metas, files)
    }

    /// _use_vision 判定 + 探针装配（app.py L1869 的 get_config().get 逐字）：
    /// 开关关 → nil（图片仅标注）；开关开 → 闭包（model 取 config default_model，
    /// 缺省 "qwen3.8"；固定 ollama connector——get_ollama_connector() 不走后端工厂）。
    public static func visionProbeIfEnabled(
        config: [String: JSONValue],
        connector: any NativeVisionChatConnector) -> (@Sendable (Data, String) async -> String)? {
        guard config["vision_parse_attachments"]?.bool ?? false else { return nil }
        let model = config["default_model"]?.string ?? "qwen3.8"
        return { raw, name in
            await NativeVisionProbe.describe(raw: raw, name: name,
                                             connector: connector, model: model)
        }
    }

    /// api_create_roundtable 附件落盘（L1919-1938）：原始文件写
    /// projects/<pid>/work/roundtables/attachments/<rtid>/<safe_name>，saved_path 写回
    /// attachments 列。失败静默（不影响讨论本身）。
    public static func persistAttachmentFiles(db: NativeDatabase, projectId: String, rtId: String,
                                              metas: inout [[String: JSONValue]],
                                              files: [(name: String, raw: Data)]) {
        guard !files.isEmpty else { return }
        do {
            let dir = db.projectsRoot.appendingPathComponent(projectId)
                .appendingPathComponent("work/roundtables/attachments/\(rtId)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let invalid = CharacterSet(charactersIn: "\\/:*?\"<>|")
            for (i, f) in files.enumerated() where i < metas.count {
                let safe = f.name.components(separatedBy: invalid).joined()
                    .trimmingCharacters(in: .whitespaces)
                let fname = safe.isEmpty ? "attachment" : safe
                let fp = dir.appendingPathComponent(fname)
                try f.raw.write(to: fp)
                metas[i]["saved_path"] = .string(fp.path)
            }
            try db.updateRoundtableAttachments(projectId: projectId, rtId: rtId, attachments: metas)
        } catch {
            // 落盘失败不影响讨论本身（Python except Exception: pass 同口径）
        }
    }

    /// 圆桌行 → 面板 Roundtable（store.py _rt_row_to_dict + app.py 详情端点同构；
    /// 详情态 messages 随行；附件正文不回传——RTAttachmentMeta 模型本就不带 text 字段，
    /// 等价 app.py L1966-1967 的 `att.pop("text", None)`）。
    public static func rowToPanel(_ r: NativeRoundtableRow,
                                  messages: [NativeRoundtableMessageRow]? = nil) -> Roundtable {
        let participants: [RTParticipant] = r.participants.map { p in
            RTParticipant(id: p["id"]?.string ?? "", name: p["name"]?.string ?? "",
                          role: p["role"]?.string, model_name: p["model_name"]?.string)
        }
        let attachments: [RTAttachmentMeta]? = r.attachments.isEmpty ? nil : r.attachments.map { a in
            RTAttachmentMeta(name: a["name"]?.string ?? "",
                             size: a["size"].flatMap { $0.int }.map { Int($0) },
                             is_text: a["is_text"]?.bool,
                             truncated: a["truncated"]?.bool)
        }
        return Roundtable(
            id: r.id, topic: r.topic, participants: participants,
            moderator: r.moderator, moderator_agent_id: r.moderatorAgentId,
            max_rounds: r.maxRounds, round: r.round, status: r.status,
            minutes: r.minutes, summary: r.summary,
            messages: messages?.map { m in
                RTMessage(id: Int(m.id), rt_id: m.rtId, round: m.round,
                          agent_id: m.agentId, agent_name: m.agentName,
                          content: m.content ?? "", ok: m.ok)
            },
            attachments: attachments,
            created_at: r.createdAt, updated_at: r.updatedAt)
    }
}
