//
//  NativeRouting.swift
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

//  混合路由表（结构化常量，设置页可枚举展示）：
//    · 历史上（P2-W0 起）NativeSidecarClient 按本表把每个模块的请求分流到
//      原生内核（NativeKernel）或 HTTP 侧车；P3-W6 侧车归零后全 19 模块
//      恒 .native，本表转为移植登记处/设置页展示数据源。
//    · 移植波次在 wave 列逐条登记，operations 里逐字写清模块内例外。
//

import Foundation

// MARK: - 模块枚举（路由键）

public enum NativeModuleKind: String, CaseIterable, Sendable {
    // ── 数据层（本波移植对象）──
    case config             = "config"              // config.json 读写
    case projects           = "projects"            // 项目 CRUD（_global.db projects）
    case agents             = "agents"              // 项目内 Agent 配置 CRUD（agents.db agent_configs）
    case sessions           = "sessions"            // 会话 CRUD（sessions 表）
    case messages           = "messages"            // 历史消息读写（session_messages 等）
    case independentAgents  = "independent_agents"  // 独立 Agent（ia-<id> 命名空间）
    case stateFile          = "state_file"          // work/state.json 执行现场快照
    // ── 引擎/领域层（后续波次）──
    case chat               = "chat"                // 流式对话 / 停止 / 注入 / 导出 / 摘要
    case tasks              = "tasks"               // 委派任务（引擎编排 + 存储）
    case roundtables        = "roundtables"         // 圆桌讨论
    case workflows          = "workflows"           // 流程中心
    case knowledge          = "knowledge"           // 知识 / 记忆 / 技能
    case warehouse          = "warehouse"           // 知识仓库条目与检索
    case plugins            = "plugins"             // 插件系统
    case cuMacros           = "cu_macros"           // Computer Use 宏
    case inference          = "inference"           // 推理后端 / 模型列表 / 上下文上限
    case modelPacks         = "model_packs"         // 模型包
    case attachments        = "attachments"         // 附件解析与落盘
}

// MARK: - 路由模式

public enum NativeRouteMode: String, Sendable {
    case native        = "原生"
    // P3-W6：httpFallback（HTTP 转发）模式随 HTTP 侧车客户端层整体退役删除——
    // 全 19 模块已 .native，转发路径零调用方。
}

// MARK: - 路由条目

public struct NativeRouteEntry: Sendable, Equatable {
    public let module: NativeModuleKind
    public let mode: NativeRouteMode
    /// 设置页展示名。
    public let title: String
    /// 覆盖操作备注（模块内例外逐字写清）。
    public let operations: String
    /// 行为规格出处（subagent 仓只读源文件）。
    public let sidecarSource: String
    /// 移植波次（"—" = 未排期）。
    public let wave: String

    public init(module: NativeModuleKind, mode: NativeRouteMode, title: String,
                operations: String, sidecarSource: String, wave: String) {
        self.module = module
        self.mode = mode
        self.title = title
        self.operations = operations
        self.sidecarSource = sidecarSource
        self.wave = wave
    }
}

// MARK: - 路由表（唯一登记处）

public enum NativeRoutingTable {

    /// ⚠️ 顺序即设置页展示顺序。翻模块为 .native 时必须已有：① 原生实现
    /// ② 双跑对照测试绿 ③ 本 entry 的 operations/wave 更新。
    public static let entries: [NativeRouteEntry] = [
        .init(module: .config, mode: .native,
              title: "配置（config.json）",
              operations: "读全量 / 补丁写回 / 校验 / 未知键往返保留 / 原子写",
              sidecarSource: "sidecar/config/store.py", wave: "P2-W0"),
        .init(module: .projects, mode: .native,
              title: "项目",
              operations: "列表 / 创建 / 重命名 / 删除（项目删除无引擎编排，端点仅删行+清目录）",
              sidecarSource: "sidecar/storage/store.py", wave: "P2-W0"),
        .init(module: .agents, mode: .native,
              title: "Agent 配置",
              operations: "增删改查全量原生（P3-W1a 删除编排：取消 target/parent 在飞委派任务→sleep 1s→删行；"
                + "端点无 SSE notify 逐字复刻）",
              sidecarSource: "sidecar/storage/store.py", wave: "P2-W0/P3-W1a"),
        .init(module: .sessions, mode: .native,
              title: "会话",
              operations: "列表 / 创建 / 重命名 / 删除全量原生（P3-W1a 删除编排：取消 session/"
                + "parent_session 在飞委派任务→sleep 1s→删行→附件目录清理；docstring 声称的 "
                + "_auth_pending 清理端点未做，按实际复刻）",
              sidecarSource: "sidecar/storage/store.py", wave: "P2-W0/P3-W1a"),
        .init(module: .messages, mode: .native,
              title: "消息",
              operations: "历史读取 / 压缩记录读取走原生；写入由原生聊天循环落库（P2-W4d2 chat 已翻转）",
              sidecarSource: "sidecar/storage/store.py", wave: "P2-W0"),
        .init(module: .independentAgents, mode: .native,
              title: "独立 Agent",
              operations: "增删改查全量原生（ia-<id> 命名空间；删除无引擎编排）",
              sidecarSource: "sidecar/storage/store.py", wave: "P2-W0"),
        .init(module: .stateFile, mode: .native,
              title: "执行现场（state.json）",
              operations: "读取走原生；写入由原生聊天循环逐步落盘（P2-W4d2 chat 已翻转）",
              sidecarSource: "sidecar/app.py", wave: "P2-W0"),
        .init(module: .chat, mode: .native,
              title: "流式对话",
              operations: "chatStream / stopChat / 注入 / 授权决议 全量原生（P2-W4d2：app.py "
                + "L1069-1622 端点装配——五 ctx 注入条件 / SSE 行序列化逐字节对齐 _sse_format / "
                + "M5 心跳动态间隔 / 取消硬停止 / compact_auto 服务端闭环 / 错误安全网 / finally "
                + "全清理，经 NativeChatRuntime + NativeAuthCenter（R2 授权记忆）+ NativeCompactor）；"
                + "openai_compatible 后端的 chatStream 已翻原生（P3-W2b：NativeOpenAIChatConnector "
                + "逐行为移植 openai_compat.py——SSE data: 行解析 / stream_options.include_usage / "
                + "usage→counts 映射（prompt_tokens→prompt_eval_count、completion_tokens→eval_count，"
                + "缺省 0）/ 工具按 index 分块拼装（id·name 覆盖、arguments 追加、call_{idx} 兜底）/ "
                + "400+tools 降级 stream_error 逐字文案 / 400·500 带图剥图重试（stream:false 保留 "
                + "stream_options·tools）+ 多模态注记 / 出站过 NativeNetworkGuard / gen() 工具能力降级 "
                + "openai_compat_supports_tools=false → 降级系统消息 + toolsSpec 置空）；"
                + "model_package 后端的 chatStream 已翻原生（P3-W3a：三已知后端统一经 "
                + "NativeRoutingChatConnector 逐轮归边——routing.py L165-186，前置换装钩子惰性执行；"
                + "退化全走 MP；tiersOverride 传内核共享档位表；未知后端仍 HTTP，W2b 偏差保留）；"
                + "面板压缩/导出/摘要/删会话端点已翻原生（P3-W1a：compact 复用 "
                + "NativeCompactor，export 双分支白名单/统一目录，summarize 8000 截断+MD/DB 双落；"
                + "偏差⑧ compact 固定 ollama connector 不走后端工厂）；心跳 `: ping` 注释行进程内直通无消费方"
                + "（偏差①，仅作唤醒源）",
              sidecarSource: "sidecar/app.py + agent_engine", wave: "P2-W4a/W4d2/P3-W1a/W2b/W3a"),
        .init(module: .tasks, mode: .native,
              title: "委派任务",
              operations: "列表 / 重试 / 停止 / 进度流 全量原生（P2-W4d2：app.py L1643-1825 端点面——"
                + "limit 钳制 / 404 / 400 文案链 / 沙盒解析 / authorizer=nil 重跑逐字；tasks/stream "
                + "snapshot 权威基线 + 原生总线增量 + _subscribed/_idle 过滤逐行为）；委派执行内核 "
                + "W4b 已原生（chat 委派与 retry 均经原生引擎推真事件，流无缺口）",
              sidecarSource: "sidecar/agent_engine + sidecar/app.py", wave: "P2-W4b/W4d2"),
        .init(module: .roundtables, mode: .native,
              title: "圆桌讨论",
              operations: "列表 / 详情 / 创建（含附件预处理+落盘）/ 继续 / 结束 / 停止 / 导出 / 删除 "
                + "全量原生（P2-W4d2：app.py L1855-2038 端点面 + W4d1 执行内核 + A13 总线）；"
                + "无 SSE——面板 5s 轮询以 DB 为唯一真相源；vision_parse_attachments 图片视觉识别 "
                + "P3-W1b 已接管（_vision_parse 逐行为：固定 ollama connector + config default_model "
                + "+ prompt 逐字 + ANY 失败空串仅标注不阻塞创建）",
              sidecarSource: "sidecar/app.py + agent_engine", wave: "P2-W4d/P3-W1b"),
        .init(module: .workflows, mode: .native,
              title: "流程中心",
              operations: "定义 CRUD / 校验 / 运行 SSE / 运行记录 / 审批 / 停止 全量原生（P2-W2）；"
                + "tool 节点已点亮（P2-W3a：list_dir/read_file/write_file/create_dir/delete_path/"
                + "web_search/install_plugin/install_skill 八工具原生，authorizer=nil 敏感操作按 "
                + "Python execute(..., None) 口径拒绝；web_search 出站过 NativeNetworkGuard）；"
                + "create_document 与 doc_reader（Office 生成/解析）留 P2-W3b，如实报 not_ported；"
                + "code 节点经 python3 子进程执行（引擎内嵌解释器不适用）；"
                + "OOXML file_read 解析未覆盖（同 P2-W1 仓库口径）；"
                + "model_package 后端未接管（chat 节点如实报错）；"
                + "A13 资源变更：原生写路径（含 app_control Agent 路径）已接原生总线 "
                + "NativeAppEvents（P2-W4d2）；events/stream 客户端已翻原生（P3-W6，偏差⑦"
                + "收口——插件/CU宏/模型包事件全由原生总线携带）",
              sidecarSource: "sidecar/workflow + sidecar/tools", wave: "P2-W2/W3a/P3-W6"),
        .init(module: .knowledge, mode: .native,
              title: "知识 / 记忆 / 技能",
              operations: "知识库 .md 增删读改/启停 + 全局/项目记忆读写走原生（P2-W1）；"
                + "技能面板端点全量原生（P3-W1b：app.py L2114-2164 七端点 + skills_mgr/manager.py；"
                + "install 复用 W3a NativeToolInstall git 通道，剥代理 120s 超时；技能写无 SSE "
                + "notify 逐字复刻）；build_knowledge_text/build_memory_injection 注入由原生聊天循环"
                + "消费（P2-W4d2）；A13 资源变更：原生写路径已接原生总线（P2-W4d2），events/stream "
                + "客户端已翻原生（P3-W6，偏差⑦收口，同 workflows 条目口径）",
              sidecarSource: "sidecar/knowledge/store_knowledge.py + sidecar/skills_mgr",
              wave: "P2-W1/P3-W1b/P3-W6"),
        .init(module: .warehouse, mode: .native,
              title: "知识仓库",
              operations: "条目 CRUD / 三模式检索 / 嵌入状态 / 重建索引 / 分组 / 注入文本 / "
                + "导入两趟冲突链走原生（P2-W1，CoreML bge-m3 嵌入内生化）；"
                + "open-dir 原生 NSWorkspace 实现（macOS 恒真分支，非 macOS/超时 ok:false 分支不适用）；"
                + "knowledge/transfer 已翻原生（P3-W1b：已归档勾选跳过 404/422 两阶段、标题首条前 20 字、"
                + "add_entry 嵌入触发、按请求全量 id 标记归档 rowcount 回传、无 SSE notify 逐字）；"
                + "OOXML（docx/xlsx/xlsm/pptx）原生解析未覆盖（P2-W2 交接），导入按解析失败计 skipped",
              sidecarSource: "sidecar/knowledge/warehouse.py", wave: "P2-W1/P3-W1b"),
        .init(module: .plugins, mode: .native,
              title: "插件",
              operations: "管理面八端点全量原生（P3-W5：app.py L844-913——install git clone "
                + "过守卫+熔断上报+剥代理+120s（P2-W3a NativeToolInstall 既有通道）/ 列表 "
                + "enabled·note 两态合并+entry_point·hooks 缺省补齐 / 卸载 404+rmtree+两 "
                + "JSON 条目清理（写失败静默）/ toggle 400 文案 / note 空串=清除 / hooks "
                + "清单 manifest 读 404 逐字；A13 create·delete·update 接线同口径）；"
                + "hook 手动触发经 ADR-0046 P-A 系统 python3 子进程桥（内嵌 shim importlib "
                + "加载+asyncio 驱动+哨兵协议；60s 超时为新增行为 ⚠️VERIFY 已登记；python3 "
                + "缺席回 error 字段不 5xx；load_error→500 对齐进程内未捕获语义）；"
                + "plugins_state.json / plugins_notes.json 与 Python 同目录同格式，既有插件"
                + "零改动可读；events/stream 客户端已翻原生（P3-W6，偏差⑦收口，同 workflows "
                + "条目口径）",
              sidecarSource: "sidecar/plugin_loader + sidecar/app.py", wave: "P3-W5/W6"),
        .init(module: .cuMacros, mode: .native,
              title: "CU 宏",
              operations: "八端点全量原生（P3-W4：app.py L2453-2552——列表/权限查/权限请/"
                + "record start·stop/replay/replays 轮询/delete；录制双模式——agent=executor "
                + "挂钩语义化落步（W4c 既有），user=NativeUserRecorder 系统级捕获"
                + "（user_recorder.py 逐行为：CGEventTap listen-only + 双击合并/拖拽/打字聚合/"
                + "密码防护/自过滤状态机）；「输入监控」TCC 主体重归属原生 app（ai.vetar.native），"
                + "未授权引导文案逐字对齐 Python；回放走既有 NativeCUMacro 引擎，replay_step "
                + "步骤事件接原生总线（W4c ⚠️VERIFY 闭环）；存储 {data_root}/cu_macros/*.json "
                + "与 Python 同目录同格式，既有宏数据直接可读；events/stream 客户端已翻原生"
                + "（P3-W6，偏差⑦收口，同 workflows 条目口径）",
              sidecarSource: "sidecar/computer_use", wave: "P2-W4c/P3-W4/W6"),
        .init(module: .inference, mode: .native,
              title: "推理后端与模型",
              operations: "status / models / pull / delete / context-limit 原生（P3-W2a：ollama 面直读 "
                + "/api/tags·/api/ps·/api/show·/api/pull·/api/delete，openai_compatible 面 /models 直读，"
                + "能力表逐字（ollama 全真/openai tools 读 openai_compat_supports_tools/MP 仅 tools）；"
                + "8s 探活超时文案逐字；models 并集 source 标注 + 502 文案前缀；pull/delete 能力表门控 "
                + "400 逐字 + NDJSON 行透传 + deleted:false 不抛错；context-limit 四级回退 "
                + "config(lazy 档+ceiling)→ps→show→262144 与 unsupported/error 逐字）。MP 分支已原生 "
                + "（P3-W3a）：① backend=model_package 时 status/models/context-limit 走原生 MP 面"
                + "（base_url=驱动活动动态端口或空串、online 恒 true / 并集退化全 MP 注册表聚合 / "
                + "tier→manifest context_length→unsupported 三级，判据不 strip 同 app.py L528-529）；"
                + "② ollama·openai 后端下 models 并集的模型包部分改注册表原生直读"
                + "（mpChatConnector.listModels → endpointRow）；pull/delete 无 MP 面（能力表先行 "
                + "400 拦截，Python 同口径）；chatStream model_package 分流已翻原生（P3-W3a，见 chat "
                + "条目）；events/stream 客户端已翻原生（P3-W6，偏差⑦收口，同 workflows "
                + "条目口径）；A13 核查：推理写端点不发 resource_changed（RESOURCE_INFERENCE 唯一发布点 "
                + "是 PUT /api/config，已原生接 NativeEndpointNotify）；listModels（/api/ollama/models 面）"
                + "已翻纯原生（P3-W6：ollama 原生名单，空名单直接返回空——原生直读 /api/tags "
                + "与侧车代理同源，无语义损失）。",
              sidecarSource: "sidecar/ollama + sidecar/app.py", wave: "P3-W2a/W3a/W6"),
        .init(module: .modelPacks, mode: .native,
              title: "模型包",
              operations: "管理面全量原生（catalog 合并/下载断点续传+SHA256+进度原生总线事件/"
                + "registry/启停/删除）+ llama-server 驱动原生（三态二进制解析/健康轮询/换包/"
                + "懒加载档重启）+ MP chatStream 与 inference MP 分支翻原生（P3-W3a）；"
                + "ASR 驱动与 /api/asr/* 全量原生（P3-W3b：ORT dlopen 三态解析/fbank+LFR+CMVN "
                + "金样对齐/CTC 贪心+后处理/卸载禁用回收 onnx session）",
              sidecarSource: "sidecar/model_packs", wave: "P3-W3a/W3b"),
        .init(module: .attachments, mode: .native,
              title: "附件",
              operations: "文档路径全量原生 + 图片/音频占位语义对齐（ASR transcribe 端点已原生，"
                + "P3-W3b 随 modelPacks）；parse 端点编排（b64 400/10MB 400/200k 截断/C7 归属落盘"
                + "save_error 降级）+ 净化/同名两份保留铁律逐字（P3-W1b）",
              sidecarSource: "sidecar/attachments + sidecar/app.py + sidecar/storage/store.py",
              wave: "P3-W1b"),
    ]

    public static func entry(_ module: NativeModuleKind) -> NativeRouteEntry {
        entries.first { $0.module == module }!   // CaseIterable 全覆盖，entries 缺一会编译期测试抓住
    }

    public static func isNative(_ module: NativeModuleKind) -> Bool {
        entry(module).mode == .native
    }

    /// 已原生模块清单（设置页徽标 / 诊断用）。
    public static var nativeModules: [NativeModuleKind] {
        entries.filter { $0.mode == .native }.map(\.module)
    }
}
