//
//  NativeOnnxRuntime.swift
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

//  设计定案（P3-W3b 计划锚点 D6）：
//    · ORT 走 dlopen C API——不链接、dylib 不进 git（仓内 models/ 已 3.7G）。
//      venv/dist 均无 onnxruntime_c_api.h，OrtApi 函数表按官方 v1.29.0 头文件
//      ABI 手工镜像（425 字段全占位 + 用到的 22 个精确类型化）——出处与索引
//      锚点见 NativeOrtApiStruct.swift 文件头。
//    · dylib 三态解析链（照 NativeLlamaCppDriver 先例；P3-W6④ 驱动进 bundle
//      优先级翻转）：Bundle.main Resources/onnxruntime/libonnxruntime.dylib >
//      env VETARAI_ONNXRUNTIME > {data_root}/drivers/onnxruntime/libonnxruntime.dylib。
//      bundle 最高——包内 dylib 与 ABI 镜像（v1.29.0）同版本发行，接管 0.4.x
//      数据根后不受其中旧库影响；env 保留为开发期显式覆盖；数据根 drivers/
//      降为兜底。env 非法继续回退；
//      三态全失 → 中文明细（含已查找列表）。调用方（ASR 驱动）转成
//      PackUnavailableError 同款语义：status 面不触 ORT（Python 同款只读注册表），
//      transcribe 面才抛 409 明细——三态全失永不崩。
//    · OrtStatus → Swift throw：GetErrorMessage 取文案后 ReleaseStatus。
//    · env 句柄进程级常驻（ORT CreateEnv 本就返回共享实例；Python onnxruntime
//      模块同口径，从不 ReleaseEnv）；session/memoryInfo/value 严格配对释放
//      （D6：卸载＝释放 session）。
//    · 会话参数逐字对齐 asr_driver.py L221-226：
//      graph_optimization_level=ORT_ENABLE_ALL(99)、
//      intra_op_num_threads=max(2, cpu_count//2)、providers=["CPUExecutionProvider"]
//      （C API 缺省即 CPU EP，无需显式 append）。
//

import Foundation

/// ORT 装载/调用错误（中文明细；驱动层包成 PackUnavailableError 同款 409 语义）。
public struct NativeOnnxRuntimeError: Error, Equatable, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// dlopen 句柄 + OrtApi 函数表（一个 dylib 一份；句柄故意不 dlclose——
/// ORT 全局线程池存活期长于任何 session，进程退出由 OS 回收）。
public final class NativeOnnxRuntime: @unchecked Sendable {

    public static let envOnnxRuntime = "VETARAI_ONNXRUNTIME"
    /// ORT_API_VERSION（onnxruntime_c_api.h v1.29.0 L43）。
    public static let ortApiVersion: UInt32 = 29
    /// OrtLoggingLevel::ORT_LOGGING_LEVEL_WARNING。
    private static let logLevelWarning: Int32 = 2
    /// GraphOptimizationLevel::ORT_ENABLE_ALL（L221-222 SessionOptions 同款）。
    private static let graphOptEnableAll: UInt32 = 99

    public let path: URL
    public let versionString: String
    private let handle: UnsafeMutableRawPointer
    /// 指向 dylib 内静态 OrtApi 结构（dylib 常驻，指针生命周期 = 进程）。
    public let api: UnsafePointer<NativeOrtApi>
    /// CreateEnv 产物（共享实例语义；永不 ReleaseEnv，见文件头）。
    private let env: UnsafeMutableRawPointer

    // MARK: - 三态解析（NativeLlamaCppDriver.resolveServerBinary 先例）

    /// bundle Resources/onnxruntime/libonnxruntime.dylib > env VETARAI_ONNXRUNTIME
    /// > {data_root}/drivers/onnxruntime/libonnxruntime.dylib（P3-W6④ 翻转：
    /// bundle 最高，数据根兜底）。env 非法继续回退；
    /// 全失 → 中文明细（含已查找列表）。dylib 非可执行二进制，判定 is_file 即可
    /// （dlopen 自带格式校验，失败在 load 里如实报）。
    public static func resolveDylib(environment: [String: String],
                                    dataRootProvider: () -> URL,
                                    bundleResourceURL: URL?) throws -> URL {
        var candidates: [URL] = []
        if let res = bundleResourceURL {
            candidates.append(res.appendingPathComponent("onnxruntime/libonnxruntime.dylib"))
        }
        let raw = (environment[Self.envOnnxRuntime] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !raw.isEmpty {
            candidates.append(URL(fileURLWithPath: (raw as NSString).expandingTildeInPath))
        }
        candidates.append(dataRootProvider()
            .appendingPathComponent("drivers/onnxruntime/libonnxruntime.dylib"))
        let fm = FileManager.default
        for c in candidates {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: c.path, isDirectory: &isDir), !isDir.boolValue {
                return c
            }
        }
        let tried = candidates.map(\.path).joined(separator: "、")
        throw NativeOnnxRuntimeError(
            "未找到 onnxruntime 动态库（ASR 模型包推理引擎的本体）。"
            + "请到「模型包」面板查看安装指引，或由设置/部署方将 libonnxruntime.dylib 放入 "
            + "数据目录 drivers/onnxruntime/ 下（亦可用环境变量 VETARAI_ONNXRUNTIME 指定路径）。"
            + "已查找: \(tried.isEmpty ? "（无候选路径）" : tried)")
    }

    // MARK: - dlopen 装载

    /// dlopen + dlsym(OrtGetApiBase) + GetApi(29) + CreateEnv。
    /// GetApi(29) 返回 nil = dylib 比 1.29.0 旧（不支持 API 29），如实报错不硬闯
    /// （函数表布局按 v29 镜像，旧库字段更少，越界读就是崩）。
    public static func load(path: URL) throws -> NativeOnnxRuntime {
        guard let handle = dlopen(path.path, RTLD_NOW | RTLD_LOCAL) else {
            let err = String(cString: dlerror())
            throw NativeOnnxRuntimeError(
                "onnxruntime 动态库加载失败: \(path.lastPathComponent): \(err)")
        }
        guard let sym = dlsym(handle, "OrtGetApiBase") else {
            throw NativeOnnxRuntimeError(
                "onnxruntime 动态库缺少 OrtGetApiBase 导出符号（不是有效的 onnxruntime）: "
                + path.lastPathComponent)
        }
        typealias GetApiBaseFn = @convention(c) () -> UnsafeRawPointer?
        let getApiBase = unsafeBitCast(sym, to: GetApiBaseFn.self)
        guard let baseRaw = getApiBase() else {
            throw NativeOnnxRuntimeError("OrtGetApiBase 返回空指针: \(path.lastPathComponent)")
        }
        let base = baseRaw.assumingMemoryBound(to: NativeOrtApiBase.self)
        let version = base.pointee.getVersionString().map { String(cString: $0) } ?? "?"
        guard let apiRaw = base.pointee.getApi(ortApiVersion) else {
            throw NativeOnnxRuntimeError(
                "onnxruntime 版本过旧（实测 \(version)，需要 ≥1.29.0 / API \(ortApiVersion)）: "
                + path.lastPathComponent)
        }
        let api = apiRaw.assumingMemoryBound(to: NativeOrtApi.self)
        var envOut: UnsafeMutableRawPointer?
        guard let createEnv = api.pointee.createEnv else {
            throw NativeOnnxRuntimeError("OrtApi.CreateEnv 函数指针为空（ABI 镜像失配）")
        }
        let status = "vetarai".withCString { createEnv(logLevelWarning, $0, &envOut) }
        guard let env = envOut else {
            // CreateEnv 失败的 status 在 load 里先临时消费（api 已可用）
            let msg = status.flatMap { s -> String? in
                guard let m = api.pointee.getErrorMessage?(s) else { return nil }
                let text = String(cString: m)
                api.pointee.releaseStatus?(s)
                return text
            } ?? "未知错误"
            throw NativeOnnxRuntimeError("onnxruntime 环境创建失败: \(msg)")
        }
        if let status { api.pointee.releaseStatus?(status) }
        return NativeOnnxRuntime(path: path, versionString: version, handle: handle,
                                 api: api, env: env)
    }

    private init(path: URL, versionString: String, handle: UnsafeMutableRawPointer,
                 api: UnsafePointer<NativeOrtApi>, env: UnsafeMutableRawPointer) {
        self.path = path
        self.versionString = versionString
        self.handle = handle
        self.api = api
        self.env = env
    }

    // MARK: - OrtStatus → Swift error

    /// 消费 OrtStatus：nil = 成功；非 nil 取 GetErrorMessage 文案（ReleaseStatus 后抛）。
    func check(_ status: UnsafeMutableRawPointer?, _ context: String) throws {
        guard let status else { return }
        var msg = "未知错误"
        if let getErrorMessage = api.pointee.getErrorMessage,
           let cstr = getErrorMessage(status) {
            msg = String(cString: cstr)
        }
        api.pointee.releaseStatus?(status)
        throw NativeOnnxRuntimeError("\(context): \(msg)")
    }

    // MARK: - 会话

    /// InferenceSession 等价物（asr_driver._ensure_loaded L221-226 同款参数）。
    /// Python 加载异常 → PackUnavailableError("ONNX 模型加载失败: <名>: <原因>")（L226-228 逐字前缀）。
    public func createSession(modelPath: URL) throws -> NativeOnnxSession {
        guard let createSessionOptions = api.pointee.createSessionOptions,
              let setGraphOpt = api.pointee.setSessionGraphOptimizationLevel,
              let setIntraThreads = api.pointee.setIntraOpNumThreads,
              let createSession = api.pointee.createSession else {
            throw NativeOnnxRuntimeError("OrtApi 会话函数指针为空（ABI 镜像失配）")
        }
        var optsOut: UnsafeMutableRawPointer?
        try check(createSessionOptions(&optsOut), "创建 SessionOptions 失败")
        guard let opts = optsOut else {
            throw NativeOnnxRuntimeError("创建 SessionOptions 失败: 返回空指针")
        }
        defer { api.pointee.releaseSessionOptions?(opts) }
        try check(setGraphOpt(opts, Self.graphOptEnableAll), "设置图优化等级失败")
        // max(2, (os.cpu_count() or 4) // 2)（L223 逐字）
        let threads = max(2, ProcessInfo.processInfo.processorCount / 2)
        try check(setIntraThreads(opts, Int32(threads)), "设置 intra_op 线程数失败")
        var sessionOut: UnsafeMutableRawPointer?
        // ORTCHAR_T = char（POSIX 分支，onnxruntime_c_api.h L111）→ UTF-8 路径直传
        let status = modelPath.path.withCString { createSession(env, $0, opts, &sessionOut) }
        try check(status, "ONNX 模型加载失败: \(modelPath.lastPathComponent)")
        guard let session = sessionOut else {
            throw NativeOnnxRuntimeError(
                "ONNX 模型加载失败: \(modelPath.lastPathComponent): 返回空会话")
        }
        return try NativeOnnxSession(rt: self, session: session)
    }
}

/// ONNX 会话（CPU EP）。ReleaseSession/ReleaseMemoryInfo 由 deinit 配对释放
/// （D6 卸载语义 = 驱动 nil 掉引用即回收）；session.run 并发纪律归调用方
/// （NativeAsrDriver 用锁串行化，Python L540-542 同款）。
public final class NativeOnnxSession {

    /// 推理用张量（CreateTensorWithDataAsOrtValue 的输入面）。bytes 生命周期
    /// 归调用方（Run 返回前不得释放/变异——本类的 run 作用域已覆盖）。
    public struct TensorInput {
        public let name: String
        public let shape: [Int64]
        /// ONNX_TENSOR_ELEMENT_DATA_TYPE（FLOAT=1 / INT32=6）。
        public let dataType: UInt32
        public let byteCount: Int
        public let bytes: UnsafeMutableRawPointer
        public init(name: String, shape: [Int64], dataType: UInt32,
                    byteCount: Int, bytes: UnsafeMutableRawPointer) {
            self.name = name
            self.shape = shape
            self.dataType = dataType
            self.byteCount = byteCount
            self.bytes = bytes
        }
    }

    /// 推理输出（数值张量面；bytes 已拷出，与 OrtValue 生命周期脱钩）。
    public struct TensorOutput {
        public let shape: [Int64]
        public let bytes: [UInt8]
        /// float32 视图（SenseVoice ctc_logits 面；本驱动输出只涉 float32/int32，
        /// 均为 4 字节——int32 视图由调用方按 bitPattern 自行转换）。
        public var floats: [Float] {
            precondition(bytes.count % 4 == 0)
            return stride(from: 0, to: bytes.count, by: 4).map {
                Float(bitPattern: UInt32(bytes[$0])
                    | UInt32(bytes[$0 + 1]) << 8
                    | UInt32(bytes[$0 + 2]) << 16
                    | UInt32(bytes[$0 + 3]) << 24)
            }
        }
        /// int32 视图（SenseVoice encoder_out_lens 面）。
        public var int32s: [Int32] {
            precondition(bytes.count % 4 == 0)
            return stride(from: 0, to: bytes.count, by: 4).map {
                Int32(bitPattern: UInt32(bytes[$0])
                    | UInt32(bytes[$0 + 1]) << 8
                    | UInt32(bytes[$0 + 2]) << 16
                    | UInt32(bytes[$0 + 3]) << 24)
            }
        }
    }

    public let rt: NativeOnnxRuntime
    private let session: UnsafeMutableRawPointer
    private let memoryInfo: UnsafeMutableRawPointer
    /// ONNX_TENSOR_ELEMENT_DATA_TYPE（onnxruntime_c_api.h L194-200）。
    public static let typeFloat: UInt32 = 1
    public static let typeInt32: UInt32 = 6

    init(rt: NativeOnnxRuntime, session: UnsafeMutableRawPointer) throws {
        self.rt = rt
        self.session = session
        guard let createCpuMemoryInfo = rt.api.pointee.createCpuMemoryInfo else {
            rt.api.pointee.releaseSession?(session)
            throw NativeOnnxRuntimeError("OrtApi.CreateCpuMemoryInfo 函数指针为空（ABI 镜像失配）")
        }
        // OrtDeviceAllocator(0) + OrtMemTypeDefault(0)
        var memOut: UnsafeMutableRawPointer?
        let status = createCpuMemoryInfo(0, 0, &memOut)
        do {
            try rt.check(status, "创建 CPU 内存信息失败")
        } catch {
            rt.api.pointee.releaseSession?(session)
            throw error
        }
        guard let mem = memOut else {
            rt.api.pointee.releaseSession?(session)
            throw NativeOnnxRuntimeError("创建 CPU 内存信息失败: 返回空指针")
        }
        self.memoryInfo = mem
    }

    deinit {
        rt.api.pointee.releaseMemoryInfo?(memoryInfo)
        rt.api.pointee.releaseSession?(session)
    }

    /// Run 等价物（asr_driver L540-543）：按名喂输入、按名收输出；
    /// 输出 bytes 立即拷出（OrtValue 当场 Release）。
    public func run(inputs: [TensorInput], outputNames: [String]) throws -> [TensorOutput] {
        let api = rt.api.pointee
        guard let createTensor = api.createTensorWithDataAsOrtValue,
              let runFn = api.run,
              let getTypeAndShape = api.getTensorTypeAndShape,
              let getDimsCount = api.getDimensionsCount,
              let getDims = api.getDimensions,
              let getMutableData = api.getTensorMutableData else {
            throw NativeOnnxRuntimeError("OrtApi 推理函数指针为空（ABI 镜像失配）")
        }

        var inputValues: [UnsafeMutableRawPointer?] = []
        defer {
            for v in inputValues { api.releaseValue?(v) }
        }
        for inp in inputs {
            var valueOut: UnsafeMutableRawPointer?
            var shape = inp.shape
            let status = shape.withUnsafeBufferPointer { shapeBuf in
                createTensor(memoryInfo, inp.bytes, inp.byteCount,
                             shapeBuf.baseAddress, shape.count, inp.dataType, &valueOut)
            }
            try rt.check(status, "创建输入张量失败: \(inp.name)")
            guard let value = valueOut else {
                throw NativeOnnxRuntimeError("创建输入张量失败: \(inp.name): 返回空指针")
            }
            inputValues.append(value)
        }
        // 名字表：Swift String → 存续整个调用域的 C 串（strdup 持有，作用域结束统一 free）。
        let inputNameHolders = inputs.map { NativeOrtCString($0.name) }
        let outputNameHolders = outputNames.map { NativeOrtCString($0) }
        let inputNamePtrs: [UnsafePointer<CChar>?] = inputNameHolders.map { $0.ptr }
        let outputNamePtrs: [UnsafePointer<CChar>?] = outputNameHolders.map { $0.ptr }

        var outputs = [UnsafeMutableRawPointer?](repeating: nil, count: outputNames.count)
        let runStatus = inputNamePtrs.withUnsafeBufferPointer { inNames in
            inputValues.withUnsafeBufferPointer { inVals in
                outputNamePtrs.withUnsafeBufferPointer { outNames in
                    runFn(session, nil, inNames.baseAddress, inVals.baseAddress,
                          inputValues.count, outNames.baseAddress, outputNames.count, &outputs)
                }
            }
        }
        try rt.check(runStatus, "ONNX 推理失败")
        defer {
            for v in outputs { if let v { api.releaseValue?(v) } }
        }

        return try outputs.enumerated().map { idx, vOpt in
            guard let v = vOpt else {
                throw NativeOnnxRuntimeError("ONNX 推理输出为空: \(outputNames[idx])")
            }
            var infoOut: UnsafeMutableRawPointer?
            try rt.check(getTypeAndShape(v, &infoOut), "读取输出形状失败")
            guard let info = infoOut else {
                throw NativeOnnxRuntimeError("读取输出形状失败: 返回空指针")
            }
            defer { api.releaseTensorTypeAndShapeInfo?(info) }
            var rank = 0
            try rt.check(getDimsCount(info, &rank), "读取输出维度数失败")
            var dims = [Int64](repeating: 0, count: rank)
            try rt.check(getDims(info, &dims, rank), "读取输出维度失败")
            var dataPtr: UnsafeMutableRawPointer?
            try rt.check(getMutableData(v, &dataPtr), "读取输出数据失败")
            guard let data = dataPtr else {
                throw NativeOnnxRuntimeError("读取输出数据失败: 返回空指针")
            }
            let elemCount = dims.reduce(1) { $0 * Int($1) }
            let byteCount = elemCount * 4   // 本驱动只消费 float32/int32 输出（SenseVoice 契约）
            let bytes = [UInt8](UnsafeRawBufferPointer(start: data, count: byteCount))
            return TensorOutput(shape: dims, bytes: bytes)
        }
    }
}

/// String → strdup 持有的稳定 C 串（deinit free；生命周期 = 持有它的作用域）。
private final class NativeOrtCString {
    let ptr: UnsafePointer<CChar>?
    private let raw: UnsafeMutablePointer<CChar>?
    init(_ s: String) {
        raw = strdup(s)
        ptr = raw.map { UnsafePointer($0) }
    }
    deinit { free(raw) }
}
