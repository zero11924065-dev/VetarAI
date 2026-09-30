//
//  WorkflowMeta.swift
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

//  工作流节点类型元数据与工厂（纯数据/纯函数，可单测）：
//    · WorkflowNodeMeta —— 类型 → 中文标签 + 分类色（移植 WorkflowCanvas.tsx TYPE_META，
//      含 A12 降饱和色 #8578C8/#5B8DB8/#5FA388；主题色用 VTheme token 保持深浅跟随）
//    · nodeTypeOptions / conditionOps —— 编辑器下拉清单（移植 WorkflowEditor.tsx 常量，
//      顺序即现状下拉顺序）
//    · WorkflowNodeFactory —— addNode 缺省字段链（逐分支对齐 WorkflowEditor.tsx），
//      节点 id 生成（n{数量+1}，撞名补随机后缀）
//

import SwiftUI

// MARK: - 节点类型元数据

public struct WorkflowNodeMeta: Equatable {
    public let label: String
    public let color: Color
}

public enum WorkflowNodeTypes {
    /// TYPE_META 移植（未知类型回落：label=类型原文，color=次级文本色）。
    public static func meta(for type: String) -> WorkflowNodeMeta {
        switch type {
        case "start":       return .init(label: "开始", color: VTheme.ok)
        case "inference":   return .init(label: "推理", color: VTheme.accent)
        case "tool":        return .init(label: "工具", color: VTheme.warn)
        case "condition":   return .init(label: "条件", color: VTheme.warn)
        // A12：分类色降饱和（方向A 语义色柔和化）
        case "parallel":    return .init(label: "并行", color: Color(hex: 0x8578C8))
        case "loop":        return .init(label: "循环", color: Color(hex: 0x8578C8))
        case "approval":    return .init(label: "审批", color: VTheme.danger)
        case "file_input":  return .init(label: "文件输入", color: Color(hex: 0x5B8DB8))
        case "file_read":   return .init(label: "文件读取", color: Color(hex: 0x5B8DB8))
        case "file_output": return .init(label: "文件输出", color: Color(hex: 0x5B8DB8))
        // TS-121（0.3.1 补遗1）
        case "text_output": return .init(label: "文本输出", color: Color(hex: 0x5FA388))
        case "variable_set": return .init(label: "变量赋值", color: Color(hex: 0x5FA388))
        case "code":        return .init(label: "代码执行", color: VTheme.warn)
        case "reply":       return .init(label: "消息回复", color: Color(hex: 0x5FA388))
        case "end":         return .init(label: "结束", color: VTheme.textSecondary)
        default:            return .init(label: type, color: VTheme.textSecondary)
        }
    }

    /// 新增节点下拉选项（value, label）——对齐 WorkflowEditor.tsx NODE_TYPE_OPTIONS。
    /// 注意：start 不可新增（恰一个开始节点由后端 strict 校验把关）。
    public static let addOptions: [(value: String, label: String)] = [
        ("inference", "推理（模型纯调用）"),
        ("tool", "工具（写文件等）"),
        ("condition", "条件分支"),
        ("parallel", "并行"),
        ("loop", "循环"),
        ("approval", "人工审批"),
        ("file_input", "文件输入（选本机文件）"),
        ("file_read", "文件读取（批量读内容）"),
        ("file_output", "文件输出（保存到本机）"),
        ("text_output", "文本输出（模板拼文本）"),
        ("variable_set", "变量赋值"),
        ("code", "代码执行（本地 Python）"),
        ("reply", "消息回复（推给会话）"),
        ("end", "结束"),
    ]

    /// 条件运算符（value, label）——对齐 CONDITION_OPS（与 schema.py CONDITION_OPERATORS 同集）。
    public static let conditionOps: [(value: String, label: String)] = [
        ("contains", "包含"),
        ("not_contains", "不包含"),
        ("equals", "等于"),
        ("starts_with", "开头是"),
        ("regex", "正则匹配"),
        ("empty", "为空"),
        ("not_empty", "非空"),
    ]

    /// empty/not_empty 不需要匹配值（编辑器据此隐藏 value 输入框）。
    public static let opsWithoutValue: Set<String> = ["empty", "not_empty"]
}

// MARK: - 节点工厂（对齐 WorkflowEditor.tsx addNode / id 生成）

public enum WorkflowNodeFactory {

    /// 新节点默认标签（TSX labelMap）。
    public static func defaultLabel(for type: String) -> String {
        switch type {
        case "inference": return "推理节点"
        case "tool": return "工具节点"
        case "condition": return "条件分支"
        case "parallel": return "并行节点"
        case "loop": return "循环节点"
        case "approval": return "人工审批"
        case "file_input": return "文件输入"
        case "file_read": return "文件读取"
        case "file_output": return "文件输出"
        case "text_output": return "文本输出"
        case "variable_set": return "变量赋值"
        case "code": return "代码执行"
        case "reply": return "消息回复"
        case "end": return "结束"
        default: return type
        }
    }

    /// 生成节点 id：n{现有节点数+1}；撞名时追加 _{100...999} 随机后缀直到唯一
    /// （对齐 TSX `let id = 'n' + idx; while (冲突) id += '_' + random`）。
    public static func generateID(existing: [WorkflowNode],
                                  randomSuffix: () -> Int = { Int.random(in: 100...999) }) -> String {
        var id = "n\(existing.count + 1)"
        while existing.contains(where: { $0.id == id }) {
            id = "\(id)_\(randomSuffix())"
        }
        return id
    }

    /// 按类型造缺省节点（逐分支对齐 addNode 的字段初始化；models 首个进推理节点缺省）。
    public static func makeNode(type: String, id: String, models: [String] = []) -> WorkflowNode {
        var props: [String: JSONValue] = ["label": .string(defaultLabel(for: type))]
        switch type {
        case "inference":
            props["model"] = .string(models.first ?? "")
            props["prompt"] = .string("")
            props["retry"] = .int(0)
        case "tool":
            props["tool"] = .string("write_file")
            props["args"] = .object([:])
        case "condition":
            props["match"] = .object(["variable": .string(""),
                                      "operator": .string("contains"),
                                      "value": .string("")])
        case "parallel":
            props["branches"] = .array([])
        case "loop":
            props["items"] = .string("")
            props["branch"] = .string("")
        case "approval":
            props["message"] = .string("请确认是否继续。")
        case "file_input":
            props["path"] = .string("")
            props["extensions"] = .string("")
            props["recursive"] = .bool(false)
        case "file_read":
            props["path"] = .string("")
            props["extensions"] = .string("")
            props["separator"] = .string("")
        case "file_output":
            props["dir"] = .string("")
            props["filename"] = .string("")
            props["content"] = .string("")
        case "text_output":
            props["template"] = .string("")
        case "variable_set":
            props["name"] = .string("")
            props["value"] = .string("")
        case "code":
            props["code"] = .string("")
        case "reply":
            props["text"] = .string("")
        default:
            break   // end 及其他：仅 label（TSX 无额外初始化）
        }
        return WorkflowNode(id: id, type: type, props: props)
    }
}
