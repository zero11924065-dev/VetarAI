//
//  NativeSearchTokenizer.swift
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

//  移植 subagent/sidecar/knowledge/warehouse.py `_tokenize`（⛔ 只读行为规格）。
//  Python 侧 = jieba.cut + 停用词过滤 + 空格连接，供 FTS5 索引与查询。
//
//  ⚠️ 分词器选型（如实记录）：
//    jieba 是 Python 包（大词表 + HMM），零依赖纪律下不可移植；本实现用 macOS 系统
//    NaturalLanguage NLTokenizer（.word 单元，内置中文词典分词）替代。
//    与 jieba 的切分粒度**不逐 token 一致**（如「知识仓库」jieba 1 词 / NL 可能 2 词），
//    但 FTS5 索引与查询走同一分词器，自洽；跨侧一致性由双跑对照的结果集断言背书
//    （keyword/hybrid 结果集一致，见 NativeKnowledgeDualRunTests）。
//  停用词表 _STOPWORDS 逐字复制（含重复项「及」——Set 语义去重后等价，保留原样以
//  便 diff 对照）。
//

import Foundation
import NaturalLanguage

public enum NativeSearchTokenizer {

    /// warehouse.py `_STOPWORDS` 逐字复制（中文高频停用词：参与 OR 检索会污染结果）。
    public static let stopwords: Set<String> = [
        "的", "了", "是", "在", "和", "与", "及", "或", "也", "都", "就", "而", "及",
        "我", "你", "他", "她", "它", "我们", "你们", "他们", "这", "那", "这个",
        "那个", "这些", "那些", "有", "没有", "不", "很", "最", "更", "把", "被",
        "着", "过", "吗", "呢", "啊", "吧", "呀", "哦", "嗯", "一", "个", "为",
        "以", "对", "从", "到", "向", "于", "之", "其", "此", "该", "等", "并",
        "但", "但是", "如果", "因为", "所以", "虽然", "可以", "能", "会", "要",
        "需要", "让", "请", "将", "已", "还", "再", "只", "才", "便", "即",
    ]

    /// 逐词切分（NLTokenizer .word）：返回过滤停用词后的词序列。
    /// 对齐 `jieba.cut` 后 `w.strip() and w not in _STOPWORDS` 的过滤语义。
    public static func words(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.setLanguage(.simplifiedChinese)   // 中文语境为主；英文按空格/标点切，NL 自动
        tokenizer.string = text
        var out: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let w = String(text[range])
            if !w.trimmingCharacters(in: .whitespaces).isEmpty && !stopwords.contains(w) {
                out.append(w)
            }
            return true
        }
        return out
    }

    /// `_tokenize(text)`：分词 → 过滤停用词 → 空格连接（FTS5 索引/查询共用）。
    public static func tokenize(_ text: String) -> String {
        guard !text.isEmpty else { return "" }   // Python `if not text: return ""`
        return words(text).joined(separator: " ")
    }
}
