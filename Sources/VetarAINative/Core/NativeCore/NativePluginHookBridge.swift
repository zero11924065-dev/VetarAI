//
//  NativePluginHookBridge.swift
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

//  决策依据（ADR-0046）：插件本体 = 用户 Python 代码，loader.py L279-336 的
//  importlib 进程内 exec_module Swift 无法原样承接；管理面全量原生后，hook
//  执行经 bundle 内嵌 shim.py + 系统 /usr/bin/python3 子进程桥——用户既有
//  插件零改动可跑（依赖事实 stdlib 契约：loader 从不装 dependencies）。
//
//  协议（逐字对齐 execute_hook L307-336 语义）：
//    · stdin  ← {"plugin_dir","entry_point","module_name","hook_name","agent_context"}
//    · stdout → 单行哨兵协议 "__VETARAI_PLUGIN_HOOK__:{json}"（插件自身 print
//      可能污染 stdout——取**最后一行**哨兵为准；Python 进程内执行时 print 进
//      侧车日志被忽略，桥方案天然隔离，行为等价）
//      {"result": v}     hook_fn 返回（有 __await__ 经 asyncio 驱动后）
//      {"error": str(e)} hook 调用异常（L333-334 → 200 error 字段）
//      {"no_hook": true} getattr(mod, hook_name, None) is None（L324-326 → 404）
//      {"load_error": s} exec_module/spec 异常——Python 进程内此异常**不被
//                        execute_hook 捕获**（_load_plugin_module 无 try），
//                        端点 500；桥方案如实区分，Swift 映射 500（微差④：
//                        detail 带 str(e)，Python 框架 500 为通用文案）
//    · 60s 超时（ADR-0046 新增行为——Python 侧无显式超时，防挂死必填，⚠️VERIFY
//      已在 ADR 登记）；系统 python3 缺席/启动失败 → error 字段形如执行异常，
//      不 5xx（ADR 原话）。
//
//  子进程纪律（同 NativeGitRunner/runCode 先例）：/usr/bin/python3 直起（不经
//  env——路径恒定且要存在性探测）；isRunning 轮询 + 超时 terminate→SIGKILL，
//  绝不 waitUntilExit（Foundation 终止事件竞态死等教训）；stdout/stderr 边跑
//  边攒防管道缓冲满阻塞；环境**不**剥离代理变量（Python 进程内执行本就继承
//  sidecar 环境，hook 用户代码出站语义保持原样——与 git clone 的守卫唯一
//  漏斗契约不同域）。
//

import Foundation

// MARK: - 桥执行结果

public enum NativePluginHookOutcome: Sendable, Equatable {
    /// {"plugin","hook","result"} 200（result 可为 null——hook 返回 None）。
    case result(JSONValue)
    /// {"plugin","hook","error"} 200（hook 调用异常 str(e) 原文 / python3 缺席 / 超时）。
    case error(String)
    /// 无此 hook（getattr None / spec None）→ 端点 404。
    case noHook
    /// 模块加载异常（Python 进程内语义 = 未捕获 → 500）→ 端点 500。
    case loadError(String)
}

// MARK: - 桥执行器（注入缝）

public struct NativePluginHookRunner: Sendable {
    /// （插件目录, entry_point, module_name, hook_name, agent_context）→ 结果。
    public var run: @Sendable (_ pluginDir: URL, _ entryPoint: String, _ moduleName: String,
                               _ hookName: String, _ agentContext: [String: JSONValue])
        async -> NativePluginHookOutcome

    public init(run: @escaping @Sendable (URL, String, String, String, [String: JSONValue])
        async -> NativePluginHookOutcome) {
        self.run = run
    }

    /// ADR-0046 新增：hook 子进程超时（Python 侧无超时——防挂死必填）。
    /// 维持写死（0.7.5 W13 口径）：插件生态兼容敏感——第三方钩子按 60s 预期实现，
    /// 放开配置会让同一插件在不同用户环境表现漂移；调参需求由下方测试缝承接。
    public static let hookTimeout = 60.0

    /// 生产执行器（/usr/bin/python3 + 内嵌 shim）。
    public static let system = NativePluginHookRunner { pluginDir, entryPoint, moduleName, hookName, ctx in
        await runViaPython3(pluginDir: pluginDir, entryPoint: entryPoint,
                            moduleName: moduleName, hookName: hookName,
                            agentContext: ctx, timeout: hookTimeout)
    }

    /// 测试缝：自定义超时（真跑 python3 验证超时杀进程路径，不必等满 60s）。
    public static func systemWithTimeout(_ timeout: Double) -> NativePluginHookRunner {
        NativePluginHookRunner { pluginDir, entryPoint, moduleName, hookName, ctx in
            await runViaPython3(pluginDir: pluginDir, entryPoint: entryPoint,
                                moduleName: moduleName, hookName: hookName,
                                agentContext: ctx, timeout: timeout)
        }
    }

    // MARK: 生产实现

    private static func runViaPython3(pluginDir: URL, entryPoint: String, moduleName: String,
                                      hookName: String, agentContext: [String: JSONValue],
                                      timeout: Double) async -> NativePluginHookOutcome {
        let fm = FileManager.default
        // 存在性探测（ADR：缺席回 error 字段形如执行异常，不 5xx）
        guard fm.isExecutableFile(atPath: "/usr/bin/python3") else {
            return .error("无法执行插件 hook：/usr/bin/python3 不存在或不可执行"
                + "（插件 hook 需要系统 Python 3，请安装 Xcode Command Line Tools）")
        }
        // shim 落临时目录（每调用独立目录，无共享态——DBG-149 纪律）
        let tmp = fm.temporaryDirectory
            .appendingPathComponent("vetarai_hook_\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tmp) }
        let shimPath = tmp.appendingPathComponent("plugin_hook_shim.py")
        do {
            try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
            try NativePluginHookShim.source.write(to: shimPath, atomically: false, encoding: .utf8)
        } catch {
            return .error("无法执行插件 hook：shim 落盘失败（\(error.localizedDescription)）")
        }
        let payload: [String: JSONValue] = [
            "plugin_dir": .string(pluginDir.path),
            "entry_point": .string(entryPoint),
            "module_name": .string(moduleName),
            "hook_name": .string(hookName),
            "agent_context": .object(agentContext),
        ]

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        proc.arguments = [shimPath.path]
        // 环境原样继承（= Python 进程内执行的 sidecar 环境语义；见文件头）
        let inPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        final class Buffer: @unchecked Sendable {
            let lock = NSLock(); var data = Data()
            func append(_ d: Data) { lock.lock(); data.append(d); lock.unlock() }
            func read() -> Data { lock.lock(); defer { lock.unlock() }; return data }
        }
        let outBuf = Buffer()
        let errBuf = Buffer()
        outPipe.fileHandleForReading.readabilityHandler = { h in outBuf.append(h.availableData) }
        errPipe.fileHandleForReading.readabilityHandler = { h in errBuf.append(h.availableData) }
        do {
            try proc.run()
        } catch {
            return .error("无法执行插件 hook：python3 启动失败（\(error.localizedDescription)）")
        }
        // stdin 喂 payload（写完即关，shim json.load(sys.stdin) 读到 EOF）
        let payloadData = Data(NativeDatabase.dumpsUTF8(.object(payload)).utf8)
        inPipe.fileHandleForWriting.write(payloadData)
        try? inPipe.fileHandleForWriting.close()

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
                return .error("插件 hook 执行超时（\(Int(timeout))s），已终止")
            }
            if Task.isCancelled {
                proc.terminate()
                return .error("插件 hook 执行已取消")
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil
        let stdout = String(decoding: outBuf.read(), as: UTF8.self)
        let stderr = String(decoding: errBuf.read(), as: UTF8.self)
        guard proc.terminationStatus == 0 else {
            let tail = stderr.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                .last { !$0.isEmpty } ?? "退出码 \(proc.terminationStatus)"
            return .error("插件 hook 桥执行失败：\(tail)")
        }
        return parseProtocol(stdout: stdout, stderr: stderr)
    }

    /// stdout 协议解析：取最后一行哨兵；解析结果对象四态。
    static func parseProtocol(stdout: String, stderr: String) -> NativePluginHookOutcome {
        let sentinel = "__VETARAI_PLUGIN_HOOK__:"
        let lines = stdout.split(separator: "\n", omittingEmptySubsequences: false)
        guard let line = lines.last(where: { $0.hasPrefix(sentinel) }),
              let payload = NativeJSONWriter.loadsFragment(Data(line.dropFirst(sentinel.count).utf8)),
              case .object(let obj) = payload else {
            let tail = stderr.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                .last { !$0.isEmpty }
            return .error("插件 hook 桥输出缺失（无协议行）"
                + (tail.map { "：\($0)" } ?? ""))
        }
        if let e = obj["load_error"]?.string { return .loadError(e) }
        if obj["no_hook"]?.bool == true { return .noHook }
        if let e = obj["error"]?.string { return .error(e) }
        if let r = obj["result"] { return .result(r) }
        return .error("插件 hook 桥输出非法（协议对象缺 result/error 键）")
    }
}

// MARK: - 内嵌 shim（ADR-0046：bundle Resources 先例缺席 → Sources 内嵌字符串）

public enum NativePluginHookShim {
    /// plugin_hook_shim.py 全文（逻辑逐字对齐 loader.py L279-336：
    /// importlib.util.spec_from_file_location 加载入口模块（不污染 sys.path）→
    /// getattr(hook_name, None) → 调用 → __await__ 经 asyncio 驱动 → 结果 JSON）。
    public static let source = #"""
import asyncio
import importlib.util
import json
import os
import sys

_SENTINEL = "__VETARAI_PLUGIN_HOOK__:"


def _emit(obj):
    # 单行协议：插件自身 print 可能污染 stdout——宿主取最后一行哨兵。
    # 行前补 \n：防插件 print 未换行导致哨兵不居行首。
    sys.stdout.write("\n" + _SENTINEL + json.dumps(obj, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def main():
    try:
        payload = json.load(sys.stdin)
    except Exception as e:
        _emit({"error": "hook 桥输入解析失败: %s" % e})
        return
    plugin_dir = payload["plugin_dir"]
    entry_point = payload["entry_point"]
    module_name = payload["module_name"]
    hook_name = payload["hook_name"]
    agent_context = payload["agent_context"]
    entry_path = os.path.join(plugin_dir, entry_point)

    # _load_plugin_module（loader.py L298-305）：spec 加载 + exec_module。
    # Python 进程内此阶段异常不被 execute_hook 捕获（→ 端点 500），桥如实区分。
    try:
        spec = importlib.util.spec_from_file_location(module_name, entry_path)
        if spec is None or spec.loader is None:
            _emit({"no_hook": True})
            return
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
    except Exception as e:
        _emit({"load_error": str(e)})
        return

    # getattr(mod, hook_name, None) is None → continue → 最终 None → 404
    hook_fn = getattr(mod, hook_name, None)
    if hook_fn is None:
        _emit({"no_hook": True})
        return

    # hook_fn(agent_context)；有 __await__ 则 await（L329-331）
    try:
        result = hook_fn(agent_context)
        if hasattr(result, "__await__"):
            async def _drive(aw):
                return await aw
            result = asyncio.run(_drive(result))
    except Exception as e:
        _emit({"error": str(e)})
        return

    try:
        _emit({"result": result})
    except Exception as e:
        # json.dumps 失败（result 不可序列化）：Python 侧 FastAPI 序列化同样
        # 会失败（框架 500）；桥降为 error 字段如实报告（微差⑤）。
        _emit({"error": "hook 结果不可 JSON 序列化: %s" % e})


main()
"""#
}
