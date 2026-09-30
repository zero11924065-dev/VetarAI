//
//  NativeStateStore.swift
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

//  逐行移植 work/state.json 的读写语义：
//    · 写：app.py L1053-1066 `_write_state_file`——<data_root>/projects/<pid>/work/state.json，
//      原子写（先 .tmp 再 os.replace），失败静默（不阻塞主链路）
//    · 读：app.py L1625-1639 `GET /api/projects/{pid}/state`——
//      不存在/异常 → {"exists": False}；存在 → {"exists": True, "state": ...}
//

import Foundation

public final class NativeStateStore: @unchecked Sendable {

    public let projectsRoot: URL
    public var log: (String) -> Void

    public init(projectsRoot: URL, log: @escaping (String) -> Void = { _ in }) {
        self.projectsRoot = projectsRoot
        self.log = log
    }

    public func stateFileURL(projectId: String) -> URL {
        projectsRoot.appendingPathComponent(projectId)
            .appendingPathComponent("work").appendingPathComponent("state.json")
    }

    /// 写执行现场（原子；失败静默——对齐 _write_state_file 的 except: pass）。
    /// 空 projectId 直接返回（对齐 `if not project_id: return`）。
    public func write(projectId: String, state: [String: JSONValue]) {
        guard !projectId.isEmpty else { return }
        do {
            let workDir = stateFileURL(projectId: projectId).deletingLastPathComponent()
            try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
            let target = stateFileURL(projectId: projectId)
            let tmp = workDir.appendingPathComponent("state.json.tmp")
            try NativeJSONWriter.dumpsObject(state, keyOrder: [])
                .write(to: tmp, atomically: false, encoding: .utf8)
            if rename(tmp.path, target.path) != 0 {
                throw NativeCoreError.io(String(cString: strerror(errno)))
            }
        } catch {
            log("state.json 落盘失败（静默）: \(error)")   // 对应 _log 无声——此处留诊断钩子
        }
    }

    /// 读执行现场（对齐端点语义：exists=false 时 state 为 nil）。
    /// 解析走 NativeJSONWriter.loads（json.loads 文本保真：浮点进度值不回读成 int）。
    public func read(projectId: String) -> (exists: Bool, state: [String: JSONValue]?) {
        do {
            let f = stateFileURL(projectId: projectId)
            guard FileManager.default.fileExists(atPath: f.path) else { return (false, nil) }
            let data = try Data(contentsOf: f)
            guard let parsed = NativeJSONWriter.loads(data),
                  case .object(let obj) = parsed else { return (false, nil) }
            return (true, obj)
        } catch {
            return (false, nil)   // 对齐端点 except: return {"exists": False}
        }
    }
}
