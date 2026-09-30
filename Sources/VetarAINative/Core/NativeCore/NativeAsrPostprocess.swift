//
//  NativeAsrPostprocess.swift
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

//  逐行为移植（⛔ 只读行为规格源：subagent/sidecar/model_packs/asr_driver.py
//  L425-508）：
//    · _ctc_greedy_decode（L499-508）：argmax → 去连续重复 → 去 blank(0) →
//      tokens.json 查表拼接（越界 id 跳过），"▁"→" "（sentencepiece DecodeIds 等价物）
//    · rich_transcription_postprocess（L470-496）：语种/情感/事件标记清理
//      （FunASR 官方 funasr/utils/postprocess_utils.py 同名函数移植）
//    · _format_str_v2（L451-467）：标记计数→抹除→选情感→事件置首→情感置尾→
//      剥离 emoji 邻接空格
//
//  口径注记：
//    ① Python str.count(sub) 计非重叠出现次数——components(separatedBy:).count-1
//      同语义（空子串永不出现：标记表全非空）。
//    ② _EMO_SET | _EVENT_SET 的遍历序在 Python 是集合哈希序（逐进程随机）——
//      12 个 emoji 两两不相交，" "+emoji / emoji+" " 替换可交换，结果与序无关，
//      Swift 侧取固定序（确定性更好，行为等价已核实）。
//    ③ Python dict 遍历保插入序（_EMO_DICT/_EVENT_DICT）——Swift 用有序数组保序。
//

import Foundation

public enum NativeAsrPostprocess {

    public static let blankId = 0

    /// _ctc_greedy_decode（L499-508）。logits 行主序 (T, V)；out_len 截断后解码。
    /// 越界 id（<0 或 ≥ tokens 数）逐字跳过（L507 `if 0 <= i < len(tokens)`）。
    public static func ctcGreedyDecode(logits: [Float], frames: Int, vocab: Int,
                                       outLen: Int, tokens: [String]) -> String {
        let t = min(outLen, frames)
        guard t > 0, vocab > 0 else { return "" }
        // argmax → 去连续重复 → 去 blank
        var prev = -1
        var ids: [Int] = []
        ids.reserveCapacity(t)
        for r in 0..<t {
            let base = r * vocab
            var best = 0
            var bestVal = logits[base]
            for c in 1..<vocab where logits[base + c] > bestVal {
                bestVal = logits[base + c]
                best = c
            }
            if best != prev {   // np.diff(yseq) != 0 等价（首帧恒保留）
                if best != blankId { ids.append(best) }
                prev = best
            }
        }
        let pieces = ids.compactMap { i -> String? in
            (i >= 0 && i < tokens.count) ? tokens[i] : nil
        }
        return pieces.joined().replacingOccurrences(of: "▁", with: " ")
    }

    // ══════════════ rich_transcription_postprocess（L429-496）══════════════

    private static let langTags = ["<|zh|>", "<|en|>", "<|yue|>", "<|ja|>", "<|ko|>", "<|nospeech|>"]

    /// _EMOJI_DICT（L431-440；计数/抹除主表，遍历序 = Python 插入序）。
    private static let emojiDict: [(tag: String, emoji: String)] = [
        ("<|nospeech|><|Event_UNK|>", "❓"),
        ("<|zh|>", ""), ("<|en|>", ""), ("<|yue|>", ""), ("<|ja|>", ""), ("<|ko|>", ""),
        ("<|nospeech|>", ""),
        ("<|HAPPY|>", "😊"), ("<|SAD|>", "😔"), ("<|ANGRY|>", "😡"), ("<|NEUTRAL|>", ""),
        ("<|BGM|>", "🎼"), ("<|Speech|>", ""), ("<|Applause|>", "👏"), ("<|Laughter|>", "😀"),
        ("<|FEARFUL|>", "😰"), ("<|DISGUSTED|>", "🤢"), ("<|SURPRISED|>", "😮"),
        ("<|Cry|>", "😭"), ("<|EMO_UNKNOWN|>", ""), ("<|Sneeze|>", "🤧"), ("<|Breath|>", ""),
        ("<|Cough|>", "😷"), ("<|Sing|>", ""), ("<|Speech_Noise|>", ""),
        ("<|withitn|>", ""), ("<|woitn|>", ""), ("<|GBG|>", ""), ("<|Event_UNK|>", ""),
    ]

    /// _EMO_DICT（L441-443；情感决选表，遍历序敏感 = Python 插入序）。
    private static let emoDict: [(tag: String, emoji: String)] = [
        ("<|HAPPY|>", "😊"), ("<|SAD|>", "😔"), ("<|ANGRY|>", "😡"), ("<|NEUTRAL|>", ""),
        ("<|FEARFUL|>", "😰"), ("<|DISGUSTED|>", "🤢"), ("<|SURPRISED|>", "😮"),
        ("<|EMO_UNKNOWN|>", ""),
    ]

    /// _EVENT_DICT（L444-446；事件置首表，遍历序敏感 = Python 插入序）。
    private static let eventDict: [(tag: String, emoji: String)] = [
        ("<|BGM|>", "🎼"), ("<|Speech|>", ""), ("<|Applause|>", "👏"),
        ("<|Laughter|>", "😀"), ("<|Cry|>", "😭"), ("<|Sneeze|>", "🤧"),
        ("<|Breath|>", ""), ("<|Cough|>", "😷"),
    ]

    private static let emoSet: Set<String> = ["😊", "😔", "😡", "😰", "🤢", "😮"]
    private static let eventSet: Set<String> = ["🎼", "👏", "😀", "😭", "🤧", "😷"]
    /// _EMO_SET | _EVENT_SET（口径注记②：替换可交换，固定序等价）。
    private static let emoEventUnion = ["😊", "😔", "😡", "😰", "🤢", "😮",
                                        "🎼", "👏", "😀", "😭", "🤧", "😷"]

    /// Python str.count(sub)：非重叠出现次数。
    private static func countOccurrences(_ s: String, _ sub: String) -> Int {
        s.components(separatedBy: sub).count - 1
    }

    /// Python s.strip()（缺省剥离空白；Swift 等价 whitespacesAndNewlines）。
    private static func pyStrip(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// _format_str_v2（L451-467）。
    static func formatStrV2(_ input: String) -> String {
        var s = input
        var sptkCount: [String: Int] = [:]
        for (sptk, _) in emojiDict {
            sptkCount[sptk] = countOccurrences(s, sptk)
            s = s.replacingOccurrences(of: sptk, with: "")
        }
        var emo = "<|NEUTRAL|>"
        for (e, _) in emoDict {
            if (sptkCount[e] ?? 0) > (sptkCount[emo] ?? 0) { emo = e }
        }
        for (e, emoji) in eventDict where (sptkCount[e] ?? 0) > 0 {
            s = emoji + s
        }
        let emoTail = emoDict.first { $0.tag == emo }?.emoji ?? ""
        s = s + emoTail
        for emoji in emoEventUnion {
            s = s.replacingOccurrences(of: " " + emoji, with: emoji)
            s = s.replacingOccurrences(of: emoji + " ", with: emoji)
        }
        return pyStrip(s)
    }

    /// rich_transcription_postprocess（L470-496）。
    public static func richTranscriptionPostprocess(_ input: String) -> String {
        func getEmo(_ x: String) -> String? {
            guard let last = x.last, emoSet.contains(String(last)) else { return nil }
            return String(last)
        }
        func getEvent(_ x: String) -> String? {
            guard let first = x.first, eventSet.contains(String(first)) else { return nil }
            return String(first)
        }
        var s = input.replacingOccurrences(of: "<|nospeech|><|Event_UNK|>", with: "❓")
        for lang in langTags {
            s = s.replacingOccurrences(of: lang, with: "<|lang|>")
        }
        // s.split("<|lang|>")（Python 保空段；omitEmpty=false）→ 逐段 format+strip(" ")
        var sList = s.components(separatedBy: "<|lang|>").map {
            formatStrV2($0).trimmingCharacters(in: CharacterSet(charactersIn: " "))
        }
        var newS = " " + (sList.first ?? "")
        var curEntEvent = getEvent(newS)
        guard sList.count > 1 else {
            return pyStrip(newS.replacingOccurrences(of: "The.", with: " "))
        }
        for i in 1..<sList.count {
            if sList[i].isEmpty { continue }
            if getEvent(sList[i]) == curEntEvent, getEvent(sList[i]) != nil {
                sList[i].removeFirst()
            }
            if sList[i].isEmpty { continue }
            curEntEvent = getEvent(sList[i])
            if let e = getEmo(sList[i]), e == getEmo(newS) {
                newS = String(newS.dropLast())
            }
            // Python s_list[i].strip().lstrip()（先全 strip 再 lstrip = strip 等价）
            newS += pyStrip(sList[i])
        }
        newS = newS.replacingOccurrences(of: "The.", with: " ")
        return pyStrip(newS)
    }
}
