//
//  main.swift
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

import Foundation
import VetarOOXML

// 样本生成器：生成 docs/pilot/samples/ 下的 sample.docx / sample.xlsx / sample.pptx。
// 用法：swift run VetarOOXMLSampleGen <输出目录>

let args = CommandLine.arguments
let outDir = args.count > 1 ? args[1] : "docs/pilot/samples"
let outURL = URL(fileURLWithPath: outDir)
try FileManager.default.createDirectory(at: outURL, withIntermediateDirectories: true)

// ---------- sample.docx：覆盖产品契约主要元素 ----------
var doc = DocXBuilder()
doc.add(.title("VetarAI 全原生 OOXML 试点 · 证据目录"))
doc.add(.heading(level: 1, text: "一、合同文件"))
doc.add(.paragraph([DocXBuilder.Run("原告"),
                    DocXBuilder.Run("张三", bold: true),
                    DocXBuilder.Run("与被告"),
                    DocXBuilder.Run("李四", italic: true),
                    DocXBuilder.Run("于 2026 年 1 月 5 日签订《买卖合同》，约定交付 100 台设备。")]))
doc.add(.heading(level: 2, text: "1.1 合同要点"))
doc.add(.bullets(["合同编号 HT-2026-001",
                  "合同金额 ￥1,234,567.89",
                  "特殊字符测试：<标签> & \"引号\""]))
doc.add(.heading(level: 1, text: "二、证据清单"))
doc.add(.table(rows: [["序号", "证据名称", "证明目的", "页码"],
                      ["1", "买卖合同原件", "合同关系成立", "3-8"],
                      ["2", "银行付款凭证", "已支付 80% 货款", "9-12"],
                      ["3", "微信聊天记录", "被告确认欠款", "13-20"]]))
doc.add(.pageBreak)
doc.add(.heading(level: 1, text: "三、法律依据"))
doc.add(.paragraph([DocXBuilder.Run("依据《中华人民共和国民法典》第五百七十七条，当事人一方不履行合同义务，应当承担违约责任。")]))
try doc.save(to: outURL.appendingPathComponent("sample.docx"))

// ---------- sample.xlsx：多 sheet / 字符串 / 数字 / 公式留位 ----------
var wb = XlsxBuilder()
wb.addSheet(name: "证据台账", rows: [
    [.string("证据编号"), .string("名称"), .string("金额"), .string("页数")],
    [.string("EV-001"), .string("买卖合同"), .number(1234567.89), .number(6)],
    [.string("EV-002"), .string("付款凭证"), .number(987654.31), .number(4)],
    [.string("合计"), .blank, .formula("C2+C3"), .formula("D2+D3")],
])
wb.addSheet(name: "时间线", rows: [
    [.string("日期"), .string("事件")],
    [.string("2026-01-05"), .string("签订合同")],
    [.string("2026-02-01"), .string("首期付款 <含贴息>")],
])
try wb.save(to: outURL.appendingPathComponent("sample.xlsx"))

// ---------- sample.pptx：多页 / 标题+正文占位 / 文本框 ----------
var prs = PptxBuilder()
prs.addSlide(title: "VetarAI 全原生 OOXML 试点汇报", bullets: [])
prs.addSlide(title: "技术路线", bullets: [
    "纯 Swift 自写 ZIP 容器（CRC32 + libz deflate）",
    "直写 OOXML：docx / xlsx / pptx",
    "零外部依赖，无 ZIPFoundation",
])
var s3 = PptxBuilder.Slide(title: "验证结论", bullets: ["textutil / xmllint / zipfile 交叉校验通过", "中文与特殊字符正常"])
s3.textBoxes.append(PptxBuilder.TextBox(x: 914400, y: 5800000, cx: 10000000, cy: 700000,
                                        paragraphs: ["W2 pilot · 2026-09"]))
prs.addSlide(s3)
try prs.save(to: outURL.appendingPathComponent("sample.pptx"))

print("samples written to \(outURL.path)")
