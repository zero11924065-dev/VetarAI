//
//  NativeRuntime.swift
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

//  原生运行时中枢（全局单例，所有面板共享同一内核连接）：
//    · 持有 NativeKernel（一个数据根一实例）并装配 NativeSidecarClient
//    · 数据根配置（UserDefaults 持久化，命令行 -sidecar.dataRoot 可覆盖——
//      冒烟脚本注入命根，键名与旧 SidecarManager 完全一致，零迁移）
//    · nativeReady：内核是进程内对象，init 同步建成即恒就绪
//    （0.5.1 R1：设置页「原生内核」路由表展示区块移除，nativeRoutingEntries
//     透传属性随删——路由表唯一权威仍是 NativeRoutingTable，测试直读）
//
//  历史（P1-W0 → P3-W6）：本类接替退役的 SidecarManager——后者管侧车子进程
//  生命周期（spawn/探活/崩溃认领）；P3-W6 HTTP 侧车客户端层整体删除后，
//  进程职责（Status 状态机/启停/端口/二进制/stderr/崩溃提示）随之归零，
//  仅存的内核装配职责迁入本类。
//
//  UserDefaults 键口径：
//    · sidecar.dataRoot —— 保留读写（兼容读：旧安装/冒烟脚本已注入的值直接生效）
//    · nativeKernel.enabled —— 恒原生后废除；读到 NO 记一行日志后忽略
//      （旧命令行/冒烟参数兼容：容忍存在，不报错、不生效）
//    · sidecar.port / sidecar.binaryPath —— 不再读取（随进程职责归零删除）
//

import Foundation

@MainActor
public final class NativeRuntime: ObservableObject {

    // ── 状态 ──

    /// 原生模块就绪态（面板就绪门统一口径）：内核是进程内对象，
    /// init 同步建成即恒 true——无远端可探、无启动窗口。
    @Published public private(set) var nativeReady: Bool = false

    // ── 配置（持久化）──

    /// 数据根路径（VETARAI_DATA_ROOT 等价）。键名保持 `sidecar.dataRoot` 不变——
    /// 兼容读旧安装已持久化的值，冒烟脚本命令行 `-sidecar.dataRoot <path>` 继续生效；
    /// 不迁新键（双键回退只会引入读写不一致面，零收益）。
    /// 解析优先级：命令行（NSArgumentDomain `-sidecar.dataRoot`）> UserDefaults
    /// 持久化 > 默认值 ~/.subagent（`string(forKey:)` 天然先查参数域）。
    @Published public var dataRootPath: String {
        didSet { defaults.set(dataRootPath, forKey: Keys.dataRoot) }
    }

    public enum Keys {
        public static let dataRoot = "sidecar.dataRoot"
        /// 已废除（恒原生）：读到 NO 记日志一行后忽略。
        public static let legacyNativeKernel = "nativeKernel.enabled"
    }

    public static var defaultDataRoot: String {
        // P3-W6④ 接管生产数据根：默认与 0.4.x 生产线同根 ~/.subagent
        // （数据格式同源兼容，原生直接读，不做首启迁移）。
        // 历史默认 ~/Library/Application Support/VetarAINative/SidecarData 弃用——
        // 旧目录数据不迁移（开发期隔离目录，非生产数据）。
        NSHomeDirectory() + "/.subagent"
    }

    /// 当前客户端（面板经 SidecarClientProtocol 调用；恒为 NativeSidecarClient，
    /// 非可选——内核 init 同步建成，无「未就绪无客户端」窗口）。
    public let client: SidecarClientProtocol

    /// 当前数据根的内核实例（诊断/测试直读用）。
    public let kernel: NativeKernel

    private let defaults: UserDefaults
    private let logger: AppLogger

    public init(defaults: UserDefaults = .standard,
                logger: AppLogger = .shared,
                clientOverride: (any SidecarClientProtocol)? = nil) {
        self.defaults = defaults
        self.logger = logger
        // 先用局部量算出数据根（self 在全部存储属性就绪前不可读），再依序赋值。
        let root = defaults.string(forKey: Keys.dataRoot) ?? Self.defaultDataRoot
        self.dataRootPath = root

        // 旧开关废除 = 恒原生：读到 NO（旧命令行/冒烟参数残留）记日志一行后忽略，
        // 不报错（冒烟脚本兼容需要）；YES/缺省静默（本就是唯一行为）。
        if defaults.object(forKey: Keys.legacyNativeKernel) != nil,
           !defaults.bool(forKey: Keys.legacyNativeKernel) {
            logger.info("nativeKernel.enabled=NO 已忽略：P3-W6 起恒原生，开关废除")
        }

        let kernel = NativeKernel(dataRoot: URL(fileURLWithPath: root),
                                  log: { [logger] m in logger.info("原生内核: \(m)") })
        self.kernel = kernel
        // clientOverride 仅供测试注入 mock 客户端（生产恒为 nil → 原生客户端）。
        self.client = clientOverride ?? NativeSidecarClient(kernel: kernel)

        // 嵌入索引兼容策略（0.5.2 A1 错峰口径，承接 SidecarManager.decorate 的
        // P2-W1 语义）：启动**不**预热、不立即重编码——0.5.1 实测启动 4.2~4.5s
        // CPU 饱和窗即来自 bge-m3 预装载，真懒加载后启动零嵌入功耗；首载由首次
        // 真实检索/入库触发（NativeSidecarClient 非 @MainActor，装载只堵该次
        // 检索请求，不冻 UI）。侧车 int8 遗留向量的重编码挂到首载成功钩子上
        // （装载本是重编码的前置，同点错峰、后台执行）；原生模型不可用则不动
        // 旧向量（检索降级）。幂等：无旧向量时近乎零开销。
        // mock 注入（测试）时不接线——内核无真实数据根，钩子无意义且拖慢测试。
        if clientOverride == nil {
            kernel.embedder.onFirstLoad = { [weak kernel] in
                Task.detached(priority: .background) {
                    kernel?.knowledge.reembedForeignModelEntriesIfNeeded()
                }
            }
            // P3-W6④ 驱动进 bundle：启动即上报三态解析命中面（只解析路径，
            // 不 dlopen/不 spawn——装载仍按需），冒烟核验「包内驱动优先」看日志即可。
            logDriverResolution(kernel: kernel)
        }

        nativeReady = true
        logger.info("原生运行时就绪：数据根 \(root)")
    }

    /// 启动期驱动解析上报（P3-W6④）：llama-server / onnxruntime 三态链
    /// （bundle > env > dataRoot）命中路径各记一行；未命中也记（明细自带
    /// 已查找列表），不 throw——解析失败只在真正用驱动时才报错。
    private func logDriverResolution(kernel: NativeKernel) {
        do {
            let bin = try kernel.llamaDriver.resolveServerBinary()
            logger.info("驱动解析 llama-server 命中: \(bin.path)")
        } catch {
            logger.info("驱动解析 llama-server 未命中: \(error)")
        }
        do {
            let dylib = try NativeOnnxRuntime.resolveDylib(
                environment: ProcessInfo.processInfo.environment,
                dataRootProvider: { kernel.dataRoot },
                bundleResourceURL: Bundle.main.resourceURL)
            logger.info("驱动解析 onnxruntime 命中: \(dylib.path)")
        } catch {
            logger.info("驱动解析 onnxruntime 未命中: \(error)")
        }
    }
}
