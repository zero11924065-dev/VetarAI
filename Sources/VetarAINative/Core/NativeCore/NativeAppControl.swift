//
//  NativeAppControl.swift
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

//  逐行为移植 subagent/sidecar/app_modules/registry.py（⛔ 只读行为规格源，670 行；
//  语义分歧以 Python 源码为准）：
//    · APP_MODULE_REGISTRY 三模块 12 动作（workflow 8 / knowledge 3 / roundtable 1），
//      description 与 params 说明逐字保留（新模块登记一条即自动可调的前瞻设计）
//    · action_needs_confirm：配置 app_control_confirm（list）优先于注册表默认
//      needs_confirm；配置 None 时用注册表默认
//    · dispatch：未知模块/动作 → 可读错误 + 列出可用项（任务161：报错必带原因与
//      纠正指引，不返回裸 unknown）；handler 异常兜底 {"ok":False,"error":type: msg}
//    · 执行器直调原生存储/引擎层（Python 直调 Python 层函数、不经 HTTP 自调用同构：
//      复用同进程 NativeWorkflowStore/NativeKnowledgeStore/NativeWorkflowEngine）
//    · _coerce_definition：Agent 常把嵌套 definition 序列化成 JSON 字符串，先容错解析
//    · workflow_run 有界等待 wait_s（0.4.11：上限 120s，退避轮询 0.4→×1.5→3.0）
//    · 写类动作复用端点语义：validate_definition(strict=False) 宽松校验（硬伤仍拦截）、
//      内置工作流不可改/删（403 文案经 _exc_detail 转可读原因）
//
//  W4c 装配：NativeAppModuleRegistry 实现 NativeAppControlDispatcher
//  （NativeChatRuntime.swift），替换 NativeAgentLoop.routeAppControl 的
//  「应用内模块控制分发链路尚未原生接管」占位。
//
//  偏差（汇报清单同步）：
//    ① roundtable.create 的参数校验逐字保留（topic/agent_ids≥2/project_id/max_rounds
//       1-20）；真创建需圆桌引擎（app.py api_create_roundtable 全链路含附件落盘/纪要
//       初始化/多轮推理），原生圆桌引擎不存在 → 校验通过后如实返回
//       roundtable_create_failed（本波砍项，理由：超出 W4c 可承范围，且前端圆桌仍走
//       HTTP 侧车，行为不回归——原生接管前该动作等于「校验通过但执行器未装配」）。
//    ② 端点层的 _notify_change（A13 app_events 推送）不在内核范围（W4c 纪律⑤：
//       SSE/事件推送属路由层）；写动作生效但面板经轮询/重进刷新。
//    ③ NODE_FIELD_SPECS 移植在本文件（schema.py L59-172 逐字）；漂移守护测试断言
//       键集与 NativeWorkflowSchema.nodeTypes 完全一致（对齐 F1 测试语义）。
//

import Foundation

// ════════════════════════════════════════════════════════════
// MARK: - NODE_FIELD_SPECS（workflow/schema.py L59-172 逐字移植；键集=NODE_TYPES）
// ════════════════════════════════════════════════════════════

public enum NativeNodeFieldSpecs {

    public struct Field: Sendable, Equatable {
        public let name: String
        public let required: Bool
        public let type: String
        public let desc: String
    }

    /// 每种节点类型一张字段表（{"name","required","type","desc"}）。
    /// ⛔ 键集必须与 NativeWorkflowSchema.nodeTypes 完全一致（漂移由测试守护）。
    /// 通用字段（不入表）：label（显示名）与 retry（失败重试次数，引擎对全类型生效）。
    public static let table: [String: [Field]] = [
        "start": [],
        "inference": [
            Field(name: "model", required: true, type: "str",
                  desc: "模型名（如 qwen3.8:latest）。纯调用：无工具、无系统提示词。"),
            Field(name: "prompt", required: false, type: "str",
                  desc: "提示词，支持 {{node.output}} / {{params.x}} / {{item}} 模板；缺省发「请处理输入。」"),
            Field(name: "images", required: false, type: "str | list[str]",
                  desc: "图片来源：变量引用（如 {{fi.output}}）或路径/data URI 列表；"
                      + "未配置时自动继承直接上游 file_input 节点或循环上下文的图片。"),
            Field(name: "retry", required: false, type: "int",
                  desc: "失败重试次数（默认 0，退避重试）。通用字段，所有节点可用。"),
            Field(name: "timeout_s", required: false, type: "number",
                  desc: "0.4.28 新增：本节点模型调用的读超时（秒，10~7200）。长任务（如大模型处理超长文本）"
                      + "可设大值（如 1200=20 分钟）；缺省用全局「非流式读超时」（设置→推理，默认 300s）。"),
        ],
        "tool": [
            Field(name: "tool", required: true, type: "str",
                  desc: "注册表工具名（如写文件/读文件/列目录等）。"),
            Field(name: "args", required: false, type: "dict",
                  desc: "工具参数；每个值支持 {{变量}} 引用。"),
        ],
        "condition": [
            Field(name: "match", required: false, type: "dict",
                  desc: "静态匹配：{variable, operator, value}；operator 取 "
                      + NativeWorkflowSchema.conditionOperators.joined(separator: "/")
                      + "（empty/not_empty 不需要 value）。"),
            Field(name: "model", required: false, type: "str",
                  desc: "配置后走动态裁判：纯调用模型判定，输出首行即分支名（when 标签）。"),
            Field(name: "prompt", required: false, type: "str",
                  desc: "动态裁判提示词（支持模板）；缺省「请判断并只输出分支名。」"),
            Field(name: "timeout_s", required: false, type: "number",
                  desc: "0.4.28 新增：动态裁判模型调用的读超时（秒，10~7200）；仅配置了 model 时生效，"
                      + "缺省用全局「非流式读超时」（默认 300s）。"),
        ],
        "parallel": [
            Field(name: "branches", required: true, type: "list[str]",
                  desc: "并行分支：节点 id 列表（单节点粒度），各分支并发执行，输出收集为列表。"),
        ],
        "loop": [
            Field(name: "items", required: true, type: "str | list",
                  desc: "要循环的列表：直接给数组或变量引用（如 {{fi.output}}）；{{item}} 逐项可用。"),
            Field(name: "branch", required: true, type: "str | list[str]",
                  desc: "循环体：单节点 id、逗号分隔链（\"ocr,save\"）或 id 数组（顺序链，"
                      + "每步输出可被后续步骤用 {{id.output}} 读取）。"),
            Field(name: "fail_policy", required: false, type: "str",
                  desc: "失败策略：abort（默认，某批失败即中止）/ skip（跳过失败批继续，continue 为别名）。"),
            Field(name: "max_failures", required: false, type: "int",
                  desc: "允许的失败批数上限（默认 0=不限制；达到上限即使 skip 也中止并报错汇总）。"),
            Field(name: "wait_ms", required: false, type: "int",
                  desc: "批间等待毫秒（默认 0）；大批量推理时给模型/系统喘息，等待期间响应停止。"),
            Field(name: "batch_size", required: false, type: "int",
                  desc: "分批大小（>1 时每轮 {{item}} 是一批列表，{{batch}} 恒为当批列表；"
                      + "用于「一次 2-3 张图发给 OCR」场景）。"),
        ],
        "approval": [
            Field(name: "message", required: false, type: "str",
                  desc: "给审批人的提示语（支持模板）；节点挂起等待人工决议，超时不限。"),
        ],
        "file_input": [
            Field(name: "path", required: true, type: "str",
                  desc: "本机文件或文件夹路径（支持 {{变量}}）；输出文件路径列表。"),
            Field(name: "extensions", required: false, type: "str",
                  desc: "扩展名过滤，逗号分隔（如 \"jpg, png\"）；不填=不过滤。"),
            Field(name: "recursive", required: false, type: "bool",
                  desc: "文件夹是否递归遍历（默认 false）。"),
        ],
        "file_output": [
            Field(name: "dir", required: true, type: "str",
                  desc: "保存目录（支持模板，不存在自动创建）。"),
            Field(name: "filename", required: true, type: "str",
                  desc: "文件名模板（支持 {{item}} / {{item_stem}} / {{node.output}} 等）；"
                      + "不允许路径分隔符与 ..（防穿越）。"),
            Field(name: "content", required: true, type: "str",
                  desc: "写入内容模板（支持 {{变量}} 引用上游输出）。"),
            Field(name: "encoding", required: false, type: "str",
                  desc: "文件编码（默认 utf-8）。"),
        ],
        "file_read": [
            Field(name: "path", required: true, type: "str",
                  desc: "单个文件或文件夹（读其内文件，支持模板）；pdf/docx/xlsx/pptx 等走解析器。"),
            Field(name: "extensions", required: false, type: "str",
                  desc: "文件夹模式下的扩展名过滤（如 \"md, txt\"）。"),
            Field(name: "separator", required: false, type: "str",
                  desc: "文件间分隔模板（支持 {{filename}}）；缺省带 === 文件名 === 标题。"),
            Field(name: "max_bytes", required: false, type: "int",
                  desc: "单文件输出文本上限（默认 200000，防超大文件撑爆上下文）；"
                      + "二进制文档为整读后解析，另有 20MB 源文件字节上限。"),
        ],
        "text_output": [
            Field(name: "template", required: true, type: "str",
                  desc: "内容模板（支持 {{node.output}} / {{params.x}} / {{item}}）；不落盘，只产出文本。"),
        ],
        "variable_set": [
            Field(name: "name", required: true, type: "str",
                  desc: "变量名：不能含 . 或 /，且不能用保留名 params/item/item_index/batch。"),
            Field(name: "value", required: false, type: "any",
                  desc: "变量值；整串 {{x}} 保持原值类型，混合模板渲染为字符串。"),
        ],
        "code": [
            Field(name: "code", required: true, type: "str",
                  desc: "Python 源码（纯本地执行，不联网）；经 variables 字典读上游，结果赋给 result 变量。"),
            Field(name: "timeout_s", required: false, type: "int",
                  desc: "执行超时秒数（1~300，默认 30）；超时节点判失败、工作流继续，"
                      + "但失控线程仍会占 CPU 直到自行结束（Python 线程不可强杀）。"),
        ],
        "reply": [
            Field(name: "text", required: true, type: "str",
                  desc: "回复文本（支持模板）；作为一条助手回复推给会话前端，同时写入节点变量。"),
        ],
        "end": [
            Field(name: "output", required: false, type: "str",
                  desc: "最终结果引用（如 {{n2.output}}）；不填则工作流结果为结束节点自身输出。"),
        ],
    ]

    /// Field → Python dict 同构 JSON（{"name","required","type","desc"}）。
    public static func fieldJSON(_ f: Field) -> JSONValue {
        .object(["name": .string(f.name), "required": .bool(f.required),
                 "type": .string(f.type), "desc": .string(f.desc)])
    }
}

// ════════════════════════════════════════════════════════════
// MARK: - 模块能力注册表 + 统一执行器（registry.py 逐行为）
// ════════════════════════════════════════════════════════════

/// 圆桌创建面（砍项①的接缝）：原生圆桌引擎接管后注入实现；
/// 未注入时 roundtable.create 校验通过后如实报 roundtable_create_failed。
public protocol NativeRoundtableCreator: Sendable {
    func createRoundtable(projectId: String, topic: String, agentIds: [String],
                          moderator: String, moderatorAgentId: String?,
                          maxRounds: Int) async -> [String: JSONValue]
}

public final class NativeAppModuleRegistry: NativeAppControlDispatcher, @unchecked Sendable {

    /// WORKFLOW_RUN_MAX_WAIT（0.4.11：wait_s 上限 120s；工具循环不可被长占）。
    public static let workflowRunMaxWait = 120.0
    /// 终态（running 为进行中）。
    public static let workflowFinalStatuses: Set<String> = ["done", "failed", "stopped"]

    private let workflowStore: NativeWorkflowStore
    private let knowledge: NativeKnowledgeStore
    private let workflowRuntime: NativeWorkflowRuntimeCenter
    private let connector: any NativeWorkflowConnector
    private let roundtableCreator: (any NativeRoundtableCreator)?
    /// 0.7.7 W6：vmodel 推理节点 agentic 执行缝（app_control 驱动的工作流
    /// 与面板入口同口径；nil = 0.7.6 单段聚合）。
    private let vmodelAgentic: NativeVModelAgenticFn?
    /// 引擎驱动接缝（测试可注入假驱动；生产默认真驱动 NativeWorkflowEngine）。
    private let engineDriver: @Sendable (String, JSONValue, [String: JSONValue], String) -> Void

    public init(workflowStore: NativeWorkflowStore,
                knowledge: NativeKnowledgeStore,
                workflowRuntime: NativeWorkflowRuntimeCenter,
                connector: any NativeWorkflowConnector,
                roundtableCreator: (any NativeRoundtableCreator)? = nil,
                vmodelAgentic: NativeVModelAgenticFn? = nil,
                engineDriver: (@Sendable (String, JSONValue, [String: JSONValue], String) -> Void)? = nil) {
        self.workflowStore = workflowStore
        self.knowledge = knowledge
        self.workflowRuntime = workflowRuntime
        self.connector = connector
        self.roundtableCreator = roundtableCreator
        self.vmodelAgentic = vmodelAgentic
        if let engineDriver {
            self.engineDriver = engineDriver
        } else {
            let store = workflowStore
            let runtime = workflowRuntime
            let conn = connector
            let agentic = vmodelAgentic
            self.engineDriver = { runId, definition, params, sandboxRoot in
                // _drive()（registry.py L160-179）：后台消费引擎事件直至结束；
                // 任何异常都落库为 failed（与端点 gen() 同构）。
                let engine = NativeWorkflowEngine(
                    runId: runId, definition: definition, connector: conn,
                    store: store, runtime: runtime,
                    sandboxRoot: sandboxRoot, params: params,
                    vmodelAgentic: agentic)
                // _drive()（registry.py L160-179）：后台消费引擎事件直至结束。
                // 原生引擎自身把异常落库为 failed（NativeWorkflowEngine.runMain 内
                // updateWorkflowRun(status:"failed")，与端点 gen() 同构兜底）。
                Task { for await _ in await engine.run() { } }   // engine 是 actor：run() 经 await
            }
        }
    }

    // MARK: - 注册表数据结构（APP_MODULE_REGISTRY 同构）

    public struct ActionSpec: Sendable {
        public let actionDescription: String
        public let params: [(String, String)]   // 保插入序（展示用）
        public let needsConfirm: Bool
    }
    public struct ModuleSpec: Sendable {
        public let moduleDescription: String
        public let actions: [(String, ActionSpec)]   // 保插入序（catalog 渲染）
    }

    /// APP_MODULE_REGISTRY（description/params 文案逐字；顺序 = Python dict 插入序）。
    public static func registry() -> [(String, ModuleSpec)] {
        let nodeTypesText = NativeWorkflowSchema.nodeTypes.joined(separator: "/")
        return [
            ("workflow", ModuleSpec(
                moduleDescription: "流程中心：可视化工作流（确定性节点编排，适合批量识图/转写/文件处理）",
                actions: [
                    ("list", ActionSpec(
                        actionDescription: "列出全部工作流（id/名称/描述）。调用 workflow_run 前先用它拿到 workflow_id。",
                        params: [], needsConfirm: false)),
                    ("get", ActionSpec(
                        actionDescription: "查看单个工作流的完整定义（含 definition 的 nodes/edges/节点字段详情），只读。"
                            + "workflow.list 只回摘要，搭建或修改前需要参考节点写法时用本动作。",
                        params: [("workflow_id", "str（必填，工作流 id；用 workflow.list 查）")],
                        needsConfirm: false)),
                    ("get_node_schema", ActionSpec(
                        actionDescription: "查询工作流节点类型的字段说明（字段名/是否必填/类型/一句话说明），只读。"
                            + "传 node_type 查单个类型；不传则返回全部类型的字段表。"
                            + "写 definition 前先查它，避免臆造字段名。",
                        params: [("node_type", "str（可选，节点类型名，如 inference/loop/file_input；不传返回全部）")],
                        needsConfirm: false)),
                    ("run", ActionSpec(
                        actionDescription: "触发运行指定工作流。工作流是长任务，默认立即返回 run_id 并在后台执行，"
                            + "之后用 get_runs 查询进度与结果。"
                            + "⚡ 若希望本轮直接拿到结果（省去反复轮询的多轮往返），可传 wait_s 有界等待：短流程等到结束即返回 "
                            + "status/result/error；长流程超时则返回 running + run_id，退回轮询。",
                        params: [
                            ("workflow_id", "str（必填，工作流 id；用 workflow.list 查）"),
                            ("params", "dict（可选，工作流入参 variables）"),
                            ("sandbox_root", "str（可选，文件节点的根目录；默认用当前会话工作目录）"),
                            ("wait_s", "float（可选，0.4.11 新增，有界等待秒数，上限 120；"
                                + "不传或 0=立即返回 run_id 后台跑；传正值=最多等这么久拿结果）"),
                        ], needsConfirm: true)),   // 高成本：会跑多节点推理、占用模型与内存
                    ("get_runs", ActionSpec(
                        actionDescription: "查询工作流运行记录与状态。传 run_id 查单次运行详情；"
                            + "传 workflow_id 查该工作流最近运行；都不传则查全局最近运行。",
                        params: [
                            ("run_id", "str（可选，单次运行 id）"),
                            ("workflow_id", "str（可选，按工作流过滤）"),
                            ("limit", "int（可选，默认 10，上限 50）"),
                        ], needsConfirm: false)),
                    ("create", ActionSpec(
                        actionDescription: "创建一个新的工作流定义（不运行）。definition 需含 nodes/edges；"
                            + "允许保存半成品（strict=False 宽松校验：节点类型无效/连线指向不存在的节点等硬伤仍会被拒，"
                            + "拒绝原因会原样返回，请据此修正后重试）。创建成功后返回 workflow_id，"
                            + "可用 workflow_run 运行、workflow_update 修改。"
                            + "合法节点类型：\(nodeTypesText)。",
                        params: [
                            ("name", "str（必填，工作流名称）"),
                            ("definition", "dict 或 JSON 字符串（必填，含 nodes/edges 的完整定义）"),
                            ("description", "str（可选，工作流说明）"),
                        ], needsConfirm: false)),   // 只写定义、不跑推理、可逆 → 不弹窗
                    ("update", ActionSpec(
                        actionDescription: "更新已有工作流的 name/description/definition（部分更新：只改你传了的字段，"
                            + "三者至少传一个）。⛔ 内置工作流不可修改（会被拒）。definition 同样走宽松校验。",
                        params: [
                            ("workflow_id", "str（必填，用 workflow_list 查）"),
                            ("name", "str（可选，新名称）"),
                            ("description", "str（可选，新说明）"),
                            ("definition", "dict 或 JSON 字符串（可选，新的完整定义；传则整体替换）"),
                        ], needsConfirm: false)),
                    ("delete", ActionSpec(
                        actionDescription: "删除一个工作流定义。⛔ 破坏性操作：定义删除后不可恢复"
                            + "（历史运行记录保留作追溯）。内置工作流不可删除（会被拒）。",
                        params: [("workflow_id", "str（必填，用 workflow_list 查）")],
                        needsConfirm: true)),   // 破坏性且不可逆 → 必须用户确认
                ])),
            ("knowledge", ModuleSpec(
                moduleDescription: "知识仓库：把对话/材料沉淀为本地知识（拉模式，永不自动注入上下文）",
                actions: [
                    ("search", ActionSpec(
                        actionDescription: "检索知识仓库（关键词+语义混合）。仅当需要引用历史沉淀时使用。",
                        params: [
                            ("query", "str（必填，检索词或自然语言描述）"),
                            ("scope", "str（可选，project/global/all，默认 all）"),
                            ("mode", "str（可选，hybrid/keyword/semantic，默认 hybrid）"),
                            ("limit", "int（可选，默认 5，上限 20）"),
                        ], needsConfirm: false)),
                    ("inject", ActionSpec(
                        actionDescription: "取出指定知识条目的正文（按 entry_ids）。返回文本供你作为依据使用；"
                            + "不会自动写入会话历史。",
                        params: [("entry_ids", "list[str]（必填，条目 id；用 knowledge.search 获取）")],
                        needsConfirm: false)),
                    ("groups", ActionSpec(
                        actionDescription: "查看知识仓库分组概览（全局/各项目的条数）。",
                        params: [], needsConfirm: false)),
                ])),
            ("roundtable", ModuleSpec(
                moduleDescription: "圆桌讨论：多个 Agent 就一个议题会诊（专家会诊模式）",
                actions: [
                    ("create", ActionSpec(
                        actionDescription: "创建圆桌讨论并执行第一轮。需至少 2 个 Agent。"
                            + "后续轮次与结束由用户在圆桌面板掌控。",
                        params: [
                            ("topic", "str（必填，讨论议题）"),
                            ("agent_ids", "list[str]（必填，≥2 个参与 Agent 的 id）"),
                            ("project_id", "str（可选，默认当前项目）"),
                            ("moderator", "str（可选，user/ai，默认 user）"),
                            ("max_rounds", "int（可选，默认 5，上限 20）"),
                        ], needsConfirm: true)),   // 高成本：多方多轮推理
                ])),
        ]
    }

    // MARK: list_actions / build_module_catalog_text

    /// 全部动作名（形如 workflow_run / knowledge_search）。
    public static func listActions() -> [String] {
        Self.registry().flatMap { mod, spec in spec.actions.map { "\(mod)_\($0.0)" } }
    }

    /// 把可用动作清单渲染为提示词文本。
    public static func buildModuleCatalogText() -> String {
        var lines: [String] = []
        for (mod, spec) in Self.registry() {
            lines.append("- \(mod)：\(spec.moduleDescription)")
            for (act, a) in spec.actions {
                lines.append("    · \(mod).\(act) — \(a.actionDescription)")
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: action_needs_confirm（配置 confirm_list 优先于注册表默认）

    public func actionNeedsConfirm(_ module: String, _ action: String,
                                   confirmList: [String]?) -> Bool {
        let name = "\(module)_\(action)"
        if let confirmList {
            return confirmList.contains(name)
        }
        for (m, spec) in Self.registry() where m == module {
            for (a, aspec) in spec.actions where a == action {
                return aspec.needsConfirm
            }
        }
        return false
    }

    // MARK: dispatch（未知模块/动作 → 可读错误 + 可用项；handler 异常兜底）

    public func dispatch(_ module: String, _ action: String, params: [String: JSONValue],
                         projectId: String, sessionId: String,
                         sandboxRoot: String) async -> [String: JSONValue] {
        let registry = Self.registry()
        guard let modSpec = registry.first(where: { $0.0 == module })?.1 else {
            return Self.err("unknown_module: 没有名为「\(module)」的应用模块。"
                + "可用模块：\(registry.map { $0.0 }.joined(separator: "、"))。")
        }
        guard modSpec.actions.contains(where: { $0.0 == action }) else {
            return Self.err("unknown_action: 模块「\(module)」没有动作「\(action)」。"
                + "该模块可用动作：\(modSpec.actions.map { $0.0 }.joined(separator: "、"))。")
        }
        let ctx = Ctx(projectId: projectId, sessionId: sessionId, sandboxRoot: sandboxRoot)
        do {
            return try await handle(module: module, action: action,
                                    params: params, ctx: ctx)
        } catch {
            return Self.err("\(String(describing: type(of: error))): \(error)")
        }
    }

    private struct Ctx {
        let projectId: String
        let sessionId: String
        let sandboxRoot: String
    }

    static func err(_ message: String) -> [String: JSONValue] {
        ["ok": .bool(false), "error": .string(message)]
    }

    private func handle(module: String, action: String, params: [String: JSONValue],
                        ctx: Ctx) async throws -> [String: JSONValue] {
        switch (module, action) {
        case ("workflow", "list"): return try workflowList()
        case ("workflow", "get"): return try workflowGet(params)
        case ("workflow", "get_node_schema"): return workflowGetNodeSchema(params)
        case ("workflow", "get_runs"): return try workflowGetRuns(params)
        case ("workflow", "run"): return try await workflowRun(params, ctx)
        case ("workflow", "create"): return try workflowCreate(params)
        case ("workflow", "update"): return try workflowUpdate(params)
        case ("workflow", "delete"): return try workflowDelete(params)
        case ("knowledge", "search"): return knowledgeSearch(params, ctx)
        case ("knowledge", "inject"): return knowledgeInject(params)
        case ("knowledge", "groups"): return knowledgeGroupsAction()
        case ("roundtable", "create"): return await roundtableCreate(params, ctx)
        default: return Self.err("unknown_action: \(module).\(action)")
        }
    }

    // MARK: - workflow.* 执行器（registry.py L61-225 / L365-460 逐行为）

    /// _workflow_list（查询类）：裁剪摘要（描述前 120 字）。
    private func workflowList() throws -> [String: JSONValue] {
        let rows = try workflowStore.listWorkflowRows()
        let brief: [JSONValue] = rows.map { w in
            .object([
                "id": .string(w.id), "name": .string(w.name),
                "description": .string(String(w.description.unicodeScalars.prefix(120))),
                "updated_at": .string(w.updatedAt),
            ])
        }
        return ["ok": .bool(true), "count": .int(Int64(brief.count)), "workflows": .array(brief)]
    }

    /// 完整工作流对象（get_workflow 同构：definition 解析失败兜底空 nodes/edges）。
    private static func workflowJSON(_ w: NativeWorkflowStore.WorkflowRow) -> JSONValue {
        var definition: JSONValue = .object(["nodes": .array([]), "edges": .array([])])
        if let data = w.definitionText.data(using: .utf8),
           case .object(let d)? = NativeJSONWriter.loads(data) {
            definition = .object(d)
        }
        return .object([
            "id": .string(w.id), "name": .string(w.name),
            "description": .string(w.description),
            "definition": definition,
            "built_in": .bool(w.builtIn),
            "created_at": .string(w.createdAt), "updated_at": .string(w.updatedAt),
        ])
    }

    /// _workflow_get（查询类；id 别名兼容）。
    private func workflowGet(_ params: [String: JSONValue]) throws -> [String: JSONValue] {
        let wfId = (params["workflow_id"]?.string ?? params["id"]?.string ?? "")
            .trimmingCharacters(in: .whitespaces)
        if wfId.isEmpty {
            return Self.err("bad_arg: 需要 workflow_id（可先用 workflow.list 查看有哪些工作流）")
        }
        guard let wf = try workflowStore.getWorkflowRow(wfId) else {
            return Self.err("workflow_not_found: 工作流 \(wfId) 不存在（可先用 workflow.list 查现有 id）")
        }
        return ["ok": .bool(true), "workflow": Self.workflowJSON(wf)]
    }

    /// _workflow_get_node_schema（查询类；NODE_FIELD_SPECS 读取转交）。
    private func workflowGetNodeSchema(_ params: [String: JSONValue]) -> [String: JSONValue] {
        let ntype = (params["node_type"]?.string ?? params["type"]?.string ?? "")
            .trimmingCharacters(in: .whitespaces)
        let nodeTypes = NativeWorkflowSchema.nodeTypes
        if !ntype.isEmpty {
            guard let fields = NativeNodeFieldSpecs.table[ntype] else {
                return Self.err("unknown_node_type: 没有名为 '\(ntype)' 的节点类型。"
                    + "合法节点类型：\(nodeTypes.joined(separator: "、"))。")
            }
            return ["ok": .bool(true), "node_type": .string(ntype),
                    "fields": .array(fields.map(NativeNodeFieldSpecs.fieldJSON))]
        }
        var schemas: [String: JSONValue] = [:]
        for t in nodeTypes {
            schemas[t] = .array((NativeNodeFieldSpecs.table[t] ?? []).map(NativeNodeFieldSpecs.fieldJSON))
        }
        return ["ok": .bool(true), "count": .int(Int64(schemas.count)),
                "node_types": .array(nodeTypes.map { .string($0) }),
                "schemas": .object(schemas),
                "note": .string("每种节点类型的字段表：name=字段名，required=是否必填，type=取值类型，desc=说明。"
                    + "通用字段：label（显示名）与 retry（失败重试次数）对所有节点可用。")]
    }

    /// 运行记录 → Python get_workflow_run 同构 JSON。
    private static func runJSON(_ r: NativeWorkflowStore.WorkflowRunRow) -> JSONValue {
        .object([
            "id": .string(r.id), "workflow_id": .string(r.workflowId),
            "status": .string(r.status),
            "current_node": r.currentNode.map { .string($0) } ?? .null,
            "variables": r.variables,
            "result": r.result.map { .string($0) } ?? .null,
            "error": r.error.map { .string($0) } ?? .null,
            "created_at": .string(r.createdAt), "updated_at": .string(r.updatedAt),
        ])
    }

    /// _workflow_get_runs（查询类；run_id 单查 / workflow_id 过滤 / 全局限 1-50 默认 10）。
    private func workflowGetRuns(_ params: [String: JSONValue]) throws -> [String: JSONValue] {
        let runId = (params["run_id"]?.string ?? "").trimmingCharacters(in: .whitespaces)
        if !runId.isEmpty {
            guard let r = try workflowStore.getWorkflowRun(runId) else {
                return Self.err("run_not_found: 运行记录 \(runId) 不存在")
            }
            return ["ok": .bool(true), "run": Self.runJSON(r)]
        }
        let wfIdRaw = (params["workflow_id"]?.string ?? "").trimmingCharacters(in: .whitespaces)
        let wfId = wfIdRaw.isEmpty ? nil : wfIdRaw
        var limit = 10
        if let raw = params["limit"], raw != .null {
            if let i = raw.int { limit = Int(i) }
            else if let d = raw.double { limit = Int(d) }
            else if let s = raw.string, let i = Int(s.trimmingCharacters(in: .whitespaces)) { limit = i }
            else { limit = 10 }
            if limit == 0 { limit = 10 }   // Python `or 10` 语义：0 为 falsy
        }
        limit = max(1, min(limit, 50))
        let runs = try workflowStore.listWorkflowRuns(workflowId: wfId, limit: limit)
        let arr: [JSONValue] = runs.map { r in
            .object([
                "id": .string(r.id), "workflow_id": .string(r.workflowId),
                "status": .string(r.status),
                "current_node": r.currentNode.map { .string($0) } ?? .null,
                "result": r.result.map { .string($0) } ?? .null,
                "error": r.error.map { .string($0) } ?? .null,
                "created_at": r.createdAt.map { .string($0) } ?? .null,
            ])
        }
        return ["ok": .bool(true), "count": .int(Int64(arr.count)), "runs": .array(arr)]
    }

    /// _workflow_run（副作用类；后台运行 + 立即返回 run_id；wait_s 有界等待）。
    private func workflowRun(_ params: [String: JSONValue], _ ctx: Ctx) async throws -> [String: JSONValue] {
        let wfId = (params["workflow_id"]?.string ?? params["id"]?.string ?? "")
            .trimmingCharacters(in: .whitespaces)
        if wfId.isEmpty {
            return Self.err("bad_arg: 需要 workflow_id（可先用 workflow_list 查看有哪些工作流）")
        }
        guard let wf = try workflowStore.getWorkflowRow(wfId) else {
            return Self.err("workflow_not_found: 工作流 \(wfId) 不存在")
        }
        let definition: JSONValue = {
            guard let data = wf.definitionText.data(using: .utf8),
                  let v = NativeJSONWriter.loads(data) else { return .object([:]) }
            return v
        }()
        let errors = NativeWorkflowSchema.validateDefinition(definition, strict: true)
        if !errors.isEmpty {
            return Self.err("工作流定义有错误：" + errors.prefix(5).joined(separator: "；"))
        }

        let wfParams: [String: JSONValue] = params["params"]?.object ?? [:]
        var sandboxRoot = (params["sandbox_root"]?.string ?? ctx.sandboxRoot)
            .trimmingCharacters(in: .whitespaces)
        if sandboxRoot.isEmpty {
            sandboxRoot = NSString(string: "~/Desktop").expandingTildeInPath
        }
        let runId = try workflowStore.createWorkflowRun(workflowId: wfId,
                                                        variables: .object(wfParams))
        // _drive()：后台消费引擎事件（见 engineDriver 注释）
        engineDriver(runId, definition, wfParams, sandboxRoot)

        // 0.4.11：有界等待（wait_s）；非法 → 0（后台模式）
        var waitS = 0.0
        if let raw = params["wait_s"], raw != .null {
            if let d = raw.double { waitS = d }
            else if let i = raw.int { waitS = Double(i) }
            else if let s = raw.string,
                    let d = Double(s.trimmingCharacters(in: .whitespaces)) { waitS = d }
        }
        waitS = max(0.0, min(waitS, Self.workflowRunMaxWait))

        if waitS > 0 {
            let start = Date()
            var poll = 0.4
            while true {
                try await Task.sleep(nanoseconds: UInt64(poll * 1_000_000_000))
                let rec = try workflowStore.getWorkflowRun(runId)
                let status = rec?.status ?? ""
                if Self.workflowFinalStatuses.contains(status) {
                    return [
                        "ok": .bool(true), "run_id": .string(runId),
                        "workflow_name": .string(wf.name),
                        "status": .string(status),
                        "waited_s": .double((Date().timeIntervalSince(start) * 10).rounded() / 10),
                        "result": rec?.result.map { .string($0) } ?? .null,
                        "error": rec?.error.map { .string($0) } ?? .null,
                        "current_node": rec?.currentNode.map { .string($0) } ?? .null,
                        "note": .string("工作流已结束（在等待窗口内完成），无需再轮询。"),
                    ]
                }
                if Date().timeIntervalSince(start) >= waitS {
                    return [
                        "ok": .bool(true), "run_id": .string(runId),
                        "workflow_name": .string(wf.name),
                        "status": .string(status.isEmpty ? "running" : status),
                        "note": .string("等待 \(Int(waitS))s 后仍未结束（工作流含多节点推理，可能需数分钟）。"
                            + "已转为后台运行，用 workflow_get_runs(run_id=\"\(runId)\") 查询进度与结果。"),
                    ]
                }
                poll = min(poll * 1.5, 3.0)   // 退避轮询，避免频繁读库
            }
        }

        return [
            "ok": .bool(true), "run_id": .string(runId),
            "workflow_name": .string(wf.name),
            "status": .string("running"),
            "note": .string("工作流已在后台开始运行。用 workflow_get_runs(run_id=...) 查询进度与结果；"
                + "若想在本轮直接拿到结果，可传 wait_s（秒，上限 "
                + "\(Int(Self.workflowRunMaxWait))）等待其结束。"),
        ]
    }

    /// _coerce_definition：definition 入参归一（容错 JSON 字符串——模型常把嵌套对象序列化）。
    private static func coerceDefinition(_ raw: JSONValue?) -> (JSONValue?, String?) {
        guard let raw, raw != .null else { return (nil, nil) }   // 未提供（update 部分更新合法）
        if case .object = raw { return (raw, nil) }
        if case .string(let s) = raw {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty { return (nil, nil) }
            guard let data = t.data(using: .utf8), let parsed = NativeJSONWriter.loads(data) else {
                return (nil, "definition 不是合法 JSON")
            }
            if case .object = parsed { return (parsed, nil) }
            return (nil, "definition 解析后应为对象（nodes/edges）")
        }
        return (nil, "definition 类型非法：应为对象或 JSON 字符串")
    }

    /// create 失败时的 hint（0.4.28：指向真实存在的读面；合法节点类型动态取自 schema）。
    private static func workflowCreateHint() -> String {
        var hint = "若是定义校验失败，请按上述错误修正 nodes/edges 后重试；"
            + "可先用 workflow.get 查看现有工作流的完整定义作参考，"
            + "用 workflow.get_node_schema 查各节点类型的字段说明。"
        hint += " 合法节点类型：\(NativeWorkflowSchema.nodeTypes.joined(separator: "、"))。"
        return hint
    }

    /// _workflow_create（写；宽松校验 strict=False，硬伤仍拦截且原因原样回传）。
    private func workflowCreate(_ params: [String: JSONValue]) throws -> [String: JSONValue] {
        let name = (params["name"]?.string ?? "").trimmingCharacters(in: .whitespaces)
        if name.isEmpty {
            return Self.err("bad_arg: 需要 name（工作流名称）")
        }
        let (definition, derr) = Self.coerceDefinition(params["definition"])
        if let derr { return Self.err("bad_arg: \(derr)") }
        guard let definition else {
            return Self.err("bad_arg: 需要 definition（含 nodes/edges 的工作流定义）")
        }
        // api_create_workflow 端点语义：validate_definition(strict=False) → 422 detail 前 5 条
        let errors = NativeWorkflowSchema.validateDefinition(definition, strict: false)
        if !errors.isEmpty {
            return ["ok": .bool(false),
                    "error": .string("workflow_create_failed: \(errors.prefix(5).joined(separator: "；"))"),
                    "hint": .string(Self.workflowCreateHint())]
        }
        let desc = params["description"]?.string ?? ""
        let wfId = try workflowStore.createWorkflow(name: name, definition: definition,
                                                    description: desc)
        // A13 双路径同覆盖（app.py L2240 + registry.py → api_create_workflow）：Agent 路径
        NativeEndpointNotify.change(NativeAppEvents.resourceWorkflow,
                                    NativeAppEvents.actionCreate,
                                    extra: ["workflow_id": .string(wfId)])
        return ["ok": .bool(true), "workflow_id": .string(wfId), "name": .string(name),
                "note": .string("工作流定义已创建（半成品也允许保存）。运行前会自动做完整性校验"
                    + "（需恰好一个 start、至少一个 end、start 可达全部节点）。")]
    }

    /// _workflow_update（写；部分更新；内置工作流不可改）。
    private func workflowUpdate(_ params: [String: JSONValue]) throws -> [String: JSONValue] {
        let wfId = (params["workflow_id"]?.string ?? params["id"]?.string ?? "")
            .trimmingCharacters(in: .whitespaces)
        if wfId.isEmpty {
            return Self.err("bad_arg: 需要 workflow_id（用 workflow_list 查）")
        }
        let (definition, derr) = Self.coerceDefinition(params["definition"])
        if let derr { return Self.err("bad_arg: \(derr)") }
        let name: String? = {
            guard let n = params["name"]?.string else { return nil }
            return n.trimmingCharacters(in: .whitespaces)
        }()
        let desc: String? = {
            guard let d = params["description"]?.string else { return nil }
            return d.trimmingCharacters(in: .whitespaces)
        }()
        if definition == nil && name == nil && desc == nil {
            return Self.err("bad_arg: 未提供任何要更新的字段"
                + "（name / description / definition 至少传一个）")
        }
        // api_update_workflow 端点语义：不存在 404 / 内置 403 / definition 宽松校验 422
        guard let wf = try workflowStore.getWorkflowRow(wfId) else {
            return Self.err("workflow_update_failed: 工作流不存在")
        }
        if wf.builtIn {
            return Self.err("workflow_update_failed: 内置工作流不可修改")
        }
        if let definition {
            let errors = NativeWorkflowSchema.validateDefinition(definition, strict: false)
            if !errors.isEmpty {
                return Self.err("workflow_update_failed: \(errors.prefix(5).joined(separator: "；"))")
            }
        }
        let ok = try workflowStore.updateWorkflow(wfId, name: name,
                                                  definition: definition, description: desc)
        if !ok {
            return Self.err("workflow_not_found: 工作流 \(wfId) 不存在或未发生更新")
        }
        // A13 双路径同覆盖（app.py L2268）：Agent 路径
        NativeEndpointNotify.change(NativeAppEvents.resourceWorkflow,
                                    NativeAppEvents.actionUpdate,
                                    extra: ["workflow_id": .string(wfId)])
        return ["ok": .bool(true), "workflow_id": .string(wfId),
                "note": .string("工作流已更新")]
    }

    /// _workflow_delete（破坏性；内置不可删；历史运行记录保留）。
    private func workflowDelete(_ params: [String: JSONValue]) throws -> [String: JSONValue] {
        let wfId = (params["workflow_id"]?.string ?? params["id"]?.string ?? "")
            .trimmingCharacters(in: .whitespaces)
        if wfId.isEmpty {
            return Self.err("bad_arg: 需要 workflow_id（用 workflow_list 查）")
        }
        // api_delete_workflow 端点语义：不存在 404 / 内置 403
        guard let wf = try workflowStore.getWorkflowRow(wfId) else {
            return Self.err("workflow_delete_failed: 工作流不存在")
        }
        if wf.builtIn {
            return Self.err("workflow_delete_failed: 内置工作流不可删除")
        }
        let ok = try workflowStore.deleteWorkflow(wfId)
        if !ok {
            return Self.err("workflow_delete_failed: 工作流 \(wfId) 未能删除"
                + "（可能不存在，或为内置工作流）")
        }
        // A13 双路径同覆盖（app.py L2281）：Agent 路径
        NativeEndpointNotify.change(NativeAppEvents.resourceWorkflow,
                                    NativeAppEvents.actionDelete,
                                    extra: ["workflow_id": .string(wfId)])
        return ["ok": .bool(true), "workflow_id": .string(wfId),
                "note": .string("工作流定义已删除（历史运行记录保留）")]
    }

    // MARK: - knowledge.* 执行器（registry.py L228-291 逐行为）

    /// _knowledge_search（查询类；拉模式 note 逐字）。
    private func knowledgeSearch(_ params: [String: JSONValue],
                                 _ ctx: Ctx) -> [String: JSONValue] {
        let q = (params["query"]?.string ?? params["q"]?.string ?? "")
            .trimmingCharacters(in: .whitespaces)
        if q.isEmpty {
            return Self.err("bad_arg: 需要 query（检索词）")
        }
        let scope = (params["scope"]?.string ?? "all").trimmingCharacters(in: .whitespaces)
        let mode = (params["mode"]?.string ?? "hybrid").trimmingCharacters(in: .whitespaces)
        var limit = 5
        if let raw = params["limit"], raw != .null {
            if let i = raw.int { limit = Int(i) }
            else if let d = raw.double { limit = Int(d) }
            else if let s = raw.string, let i = Int(s.trimmingCharacters(in: .whitespaces)) { limit = i }
            else { limit = 5 }
            if limit == 0 { limit = 5 }   // Python `or 5` 语义
        }
        limit = max(1, min(limit, 20))
        let pidRaw = (params["project_id"]?.string ?? ctx.projectId)
            .trimmingCharacters(in: .whitespaces)
        let pid = pidRaw.isEmpty ? nil : pidRaw
        let hits = knowledge.searchScoped(q, scope: scope, projectId: pid,
                                          limit: limit, mode: mode)
        let items: [JSONValue] = hits.map { h in
            .object([
                "id": .string(h.id),
                "title": .string(h.title),
                "scope": .string(h.scope),
                "score": h.score.map { .double($0) } ?? .null,
                "body": .string(String((h.body ?? "").unicodeScalars.prefix(1500))),
            ])
        }
        return ["ok": .bool(true), "count": .int(Int64(items.count)),
                "items": .array(items),
                "note": .string("检索结果仅本轮可见，不会写入对话上下文（拉模式）。")]
    }

    /// _knowledge_inject（查询类：不写库、不改会话，只是取内容）。
    private func knowledgeInject(_ params: [String: JSONValue]) -> [String: JSONValue] {
        var ids: [String] = []
        if case .string(let s)? = params["entry_ids"] ?? params["ids"] {
            ids = s.components(separatedBy: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        } else if case .array(let arr)? = params["entry_ids"] ?? params["ids"] {
            ids = arr.compactMap { $0.string }
        }
        if ids.isEmpty {
            return Self.err("bad_arg: 需要 entry_ids（知识条目 id 列表，可先用 knowledge_search 获取）")
        }
        _ = knowledge.pruneMissing()
        var parts: [String] = []
        var missing: [String] = []
        for eid in ids {
            guard let e = knowledge.getEntry(eid) else {
                missing.append(eid)
                continue
            }
            parts.append("## \(e.title)\n\n\(e.body ?? "")")
        }
        if parts.isEmpty {
            return Self.err("entries_not_found: 条目不存在或已被删除（\(missing.prefix(5).joined(separator: ", "))）")
        }
        let text = parts.joined(separator: "\n\n---\n\n")
        var out: [String: JSONValue] = [
            "ok": .bool(true), "count": .int(Int64(parts.count)),
            "text": .string(String(text.unicodeScalars.prefix(20000))),
        ]
        if !missing.isEmpty {
            out["missing"] = .array(missing.map { .string($0) })
        }
        return out
    }

    /// _knowledge_groups（查询类：全局 + 各项目的条数与目录；含外部删除对账）。
    private func knowledgeGroupsAction() -> [String: JSONValue] {
        let groups = knowledge.knowledgeGroups()
        let arr: [JSONValue] = groups.map { g in
            .object([
                "scope": .string(g.scope),
                "project_id": g.projectId.map { .string($0) } ?? .null,
                "project_name": .string(g.projectName),
                "count": .int(Int64(g.count)),
                "dir": .string(g.dir),
            ])
        }
        return ["ok": .bool(true), "count": .int(Int64(arr.count)), "groups": .array(arr)]
    }

    // MARK: - roundtable.create（校验逐字；真创建走 NativeRoundtableCreator 接缝——砍项①）

    private func roundtableCreate(_ params: [String: JSONValue],
                                  _ ctx: Ctx) async -> [String: JSONValue] {
        let topic = (params["topic"]?.string ?? "").trimmingCharacters(in: .whitespaces)
        if topic.isEmpty {
            return Self.err("bad_arg: 需要 topic（讨论议题）")
        }
        var agentIds: [String] = []
        if case .string(let s)? = params["agent_ids"] {
            agentIds = s.components(separatedBy: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        } else if case .array(let arr)? = params["agent_ids"] {
            agentIds = arr.compactMap { $0.string }
        }
        if agentIds.count < 2 {
            return Self.err("bad_arg: agent_ids 至少需要 2 个 Agent（圆桌是多方会诊）")
        }
        let pid = (params["project_id"]?.string ?? ctx.projectId)
            .trimmingCharacters(in: .whitespaces)
        if pid.isEmpty {
            return Self.err("bad_arg: 需要 project_id（圆桌属于某个项目）")
        }
        var maxRounds = 5
        if let raw = params["max_rounds"], raw != .null {
            if let i = raw.int { maxRounds = Int(i) }
            else if let d = raw.double { maxRounds = Int(d) }
            else if let s = raw.string, let i = Int(s.trimmingCharacters(in: .whitespaces)) { maxRounds = i }
            else { maxRounds = 5 }
            if maxRounds == 0 { maxRounds = 5 }   // Python `or 5` 语义
        }
        maxRounds = max(1, min(maxRounds, 20))
        guard let creator = roundtableCreator else {
            // 砍项①：原生圆桌引擎未装配（生产恒注入 NativeKernelRoundtableCreator，
            // 本分支仅测试缝可达）——如实报错，不谎称成功
            return Self.err("roundtable_create_failed: 圆桌执行链路尚未原生接管"
                + "（参数校验已通过；请改用圆桌面板创建）")
        }
        return await creator.createRoundtable(
            projectId: pid, topic: topic, agentIds: agentIds,
            moderator: (params["moderator"]?.string ?? "user"),
            moderatorAgentId: params["moderator_agent_id"]?.string,
            maxRounds: maxRounds)
    }
}
