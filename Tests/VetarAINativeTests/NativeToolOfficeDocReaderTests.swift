//
//  NativeToolOfficeDocReaderTests.swift
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

//  把 /Users/vetar/Desktop/beta/subagent/sidecar/tools/test_p4_doc_reader.py（594 行，
//  ⛔ 只读行为规格源）逐条翻译成 XCTest。语义以 Python 源码为准。
//
//  翻译清单（T1–T12 全翻）：
//    T1  docx 正文+表格按文档流顺序   → testT1_docxBodyAndTableOrder（6 断言）
//    T2  格式概要                     → testT2_formatSummary（9 断言）
//    T3  xlsx 多工作表+公式缓存兜底   → testT3_xlsxFormulaFallback（7 断言）
//    T4  pptx zip 兜底+实体解码       → testT4_pptxZipFallback（5 断言）
//    T5  pdf 文本层/无文本层          → testT5_pdfTextLayerAndScanned（6 断言）
//    T6  乱码防御                     → testT6_noGarbage（对照组 1 + 4 格式×3）
//    T7  契约与预算                   → testT7_contractAndBudget（12 断言）
//    T8  异常路径                     → testT8_errorPaths（6 断言）
//    T9  旧式 .doc/.xls/.ppt          → testT9_legacyDoc（textutil 分支）
//    T10 含图为主文档                 → testT10_imageHeavyDoc（4 断言）
//    T11 回归：txt/图片/大文本        → testT11_regression（6 断言）
//    T12 真实用户文档                 → testT12_realUserFiles（存在才跑，否则 skip）
//
//  ⚠️VERIFY 未翻清单：
//    ① MUTATE=1|2|3 变异注入机制（Python 运行时改写 registry/doc_reader 模块源码
//      + importlib.reload 的测试有效性自证手段）。Swift 静态编译无运行时改写并热
//      加载模块的等价物；其意图由 T7 的「经 registry」强断言组承担——若 read_file
//      的解析接线被撤掉（Python 变异1 等价），内容将退回字节解码乱码，
//      「含真实正文/无 PK 魔数/无替换符/带已解析头部」四条即红。
//    ② T5 的 PDF 提取引擎：规格源用 pypdf，原生用 PDFKit（NativeDocReader 头注
//      偏差①）。最小 PDF 样本两者输出结构一致，用例按规格断言；若引擎细节差异
//      导致断言失败，按任务纪律以 Python 源码为准再判定实现/测试归属。
//
//  样本构造：全部纯 Swift（NativeOfficeFixtures 手造 OOXML/PDF 字节，复刻
//  Python _make_* 样本的字节级结构），不依赖 python 运行时。
//  隔离纪律：全部 mktemp 临时目录沙盒；textutil 仅调系统 /usr/bin/textutil。
//

import XCTest
import VetarOOXML
@testable import VetarAINative

final class NativeToolOfficeDocReaderTests: XCTestCase {

    private var tmp: URL!
    private var sandbox: URL!
    private var context: NativeToolContext!

    override func setUp() {
        super.setUp()
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("w3bdocreader_\(UUID().uuidString)")
        sandbox = tmp.appendingPathComponent("sandbox")
        try? FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        context = NativeToolTestSupport.makeContext(dataRoot: tmp.appendingPathComponent("dataroot"))
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmp)
        super.tearDown()
    }

    private var root: String { NativePyPath.resolve(sandbox.path) }

    private func exec(_ tool: String, _ args: [String: JSONValue]) async -> [String: JSONValue] {
        await NativeToolRegistry.execute(tool, args: args, sandboxRoot: root,
                                         authorizer: nil, context: context)
    }

    private func extract(_ url: URL,
                         budget: Int = NativeToolRegistry.maxReadBytes) -> NativeDocReader.ExtractResult {
        NativeDocReader.extract(path: url.path, budget: budget)
    }

    // MARK: - T1 docx：正文 + 表格按文档流顺序提取

    func testT1_docxBodyAndTableOrder() throws {
        let p = sandbox.appendingPathComponent("起诉状.docx")
        try NativeOfficeFixtures.legalDocx().write(to: p)
        let (body, _) = try NativeDocReader.readDocx(path: p.path)
        XCTAssertTrue(body.contains("原告：王永斌"), String(body.prefix(200)))       // 正文含原告信息
        XCTAssertTrue(body.contains("事实与理由"), String(body.prefix(200)))         // 正文含事实与理由
        XCTAssertTrue(body.contains("民事起诉状"), String(body.prefix(200)))         // 标题保留
        // ⛔ 表格内容必须提取到（此前只遍历 paragraphs 会全丢）
        XCTAssertTrue(body.contains("返还借款本金") && body.contains("239900元"),
                      String(body.prefix(400)))
        XCTAssertTrue(body.contains("|---"), String(body.prefix(400)))             // 表格 markdown 化
        // ⛔ 顺序：表格必须夹在两段之间，不是全部堆到末尾（find 口径，缺失=-1）
        let iLead = body.range(of: "诉讼请求如下表所列")?.lowerBound
        let iCell = body.range(of: "返还借款本金")?.lowerBound
        let iTail = body.range(of: "事实与理由")?.lowerBound
        XCTAssertNotNil(iLead); XCTAssertNotNil(iCell); XCTAssertNotNil(iTail)
        if let l = iLead, let c = iCell, let t = iTail {
            XCTAssertTrue(l < c && c < t, "lead=\(l) cell=\(c) tail=\(t)")
        }
    }

    // MARK: - T2 格式概要：中文字体/字号/对齐/缩进/行距/页面

    func testT2_formatSummary() throws {
        let p = sandbox.appendingPathComponent("格式.docx")
        try NativeOfficeFixtures.legalDocx().write(to: p)
        let (_, detail) = try NativeDocReader.readDocx(path: p.path)
        XCTAssertTrue(detail.contains("【格式概要】"), String(detail.prefix(300)))     // 概要段存在
        // ⛔ 中文字体挂在 w:eastAsia 上；只读 font.name 会恒为 None
        XCTAssertTrue(detail.contains("仿宋"), String(detail.prefix(500)))
        XCTAssertTrue(detail.contains("字号=22") || detail.contains("字号=14"),
                      String(detail.prefix(500)))                                     // 字号已提取
        XCTAssertTrue(detail.contains("居中") && detail.contains("两端对齐"),
                      String(detail.prefix(500)))                                     // 对齐已转人话
        XCTAssertTrue(detail.contains("首行缩进=0.99"), String(detail.prefix(500)))   // 首行缩进
        XCTAssertTrue(detail.contains("纵向") && detail.contains("21.0"),
                      String(detail.prefix(300)))                                     // 页面尺寸与方向
        XCTAssertTrue(detail.contains("页边距"), String(detail.prefix(300)))          // 页边距已提取
        XCTAssertTrue(detail.contains("表格：1 个"), String(detail.prefix(500)))      // 表格数量
        // ⛔ 行距不得是 EMU 原值（22磅=279400 EMU，直出等于给模型看鬼数字）
        XCTAssertFalse(detail.contains("279400"), String(detail.prefix(600)))
    }

    // MARK: - T3 xlsx：多工作表 + 公式缓存缺失兜底

    func testT3_xlsxFormulaFallback() throws {
        let p = sandbox.appendingPathComponent("借款.xlsx")
        try NativeOfficeFixtures.formulaXlsx().write(to: p)
        let (body, detail) = try NativeDocReader.readXlsx(path: p.path)
        XCTAssertTrue(body.contains("239900") && body.contains("5972"),
                      String(body.prefix(300)))                                       // 数据行已提取
        XCTAssertTrue(body.contains("项目") && body.contains("金额"),
                      String(body.prefix(300)))                                       // 表头已提取
        XCTAssertTrue(body.contains("借款明细"), String(body.prefix(300)))            // 工作表名
        XCTAssertTrue(detail.contains("空工作表"), String(detail.prefix(300)))        // 结构统计含两个表
        // ⛔ data_only 只读缓存值；程序新建的表没有缓存 → 公式格会是空白被误读。
        //   必须原样显示公式并标注。
        XCTAssertTrue(body.contains("=SUM(B2:B3)"), String(body.prefix(400)))
        XCTAssertTrue(body.contains("公式未计算"), String(body.prefix(400)))
        XCTAssertTrue(detail.contains("1 个公式单元格"), String(detail.prefix(400)))
    }

    // MARK: - T4 pptx：zip 兜底提取 + XML 实体解码

    func testT4_pptxZipFallback() throws {
        let p = sandbox.appendingPathComponent("汇报.pptx")
        try NativeOfficeFixtures.zipFallbackPptx().write(to: p)
        let (body, detail) = try NativeDocReader.readPptx(path: p.path)
        XCTAssertTrue(body.contains("案件汇报"), String(body.prefix(300)))            // 文本已提取
        // ⛔ &amp; 必须解码为 &；替换顺序错了会把 &amp;lt; 二次解成 <
        XCTAssertTrue(body.contains("本金 239900 & 利息 5972"), String(body.prefix(400)))
        XCTAssertFalse(body.contains("&amp;"), String(body.prefix(400)))              // 实体未残留
        // 按页码排序（slide1 在 slide2 前，与 zip 写入序无关）
        if let a = body.range(of: "案件汇报")?.lowerBound,
           let b = body.range(of: "第二页")?.lowerBound {
            XCTAssertTrue(a < b, String(body.prefix(400)))
        } else {
            XCTFail("页文本缺失: \(body.prefix(400))")
        }
        XCTAssertTrue(detail.contains("共 2 页"), String(detail.prefix(200)))         // 页数统计
        XCTAssertTrue(detail.contains("python-pptx"), String(detail.prefix(300)))     // 如实说明提取口径
    }

    // MARK: - T5 pdf：文本层提取 + 无文本层如实提示

    func testT5_pdfTextLayerAndScanned() throws {
        let p = sandbox.appendingPathComponent("有效.pdf")
        try NativeOfficeFixtures.pdf(withText: true).write(to: p)
        let (body, detail) = try NativeDocReader.readPdf(path: p.path)
        XCTAssertTrue(body.contains("Wang Yongbin Loan 239900"), String(body.prefix(300)))
        XCTAssertTrue(detail.contains("共 1 页"), String(detail.prefix(200)))
        XCTAssertTrue(body.contains("第 1/1 页"), String(body.prefix(300)))

        let p2 = sandbox.appendingPathComponent("扫描件.pdf")
        try NativeOfficeFixtures.pdf(withText: false).write(to: p2)
        let (body2, detail2) = try NativeDocReader.readPdf(path: p2.path)
        // 无文本层如实提示（不谎称提取到内容）
        XCTAssertTrue(body2.contains("无可提取文本"), String(body2.prefix(300)))
        XCTAssertTrue(body2.contains("图像识别"), String(body2.prefix(300)))          // 提示指向图像识别
        XCTAssertTrue(detail2.contains("无文本层"), String(detail2.prefix(200)))      // 结构概要标注
    }

    // MARK: - T6 乱码防御：支持格式一律不得返回二进制垃圾

    func testT6_noGarbage() throws {
        let makers: [(String, () throws -> Data)] = [
            ("a.docx", { try NativeOfficeFixtures.legalDocx() }),
            ("b.xlsx", { try NativeOfficeFixtures.formulaXlsx() }),
            ("c.pptx", { try NativeOfficeFixtures.zipFallbackPptx() }),
            ("d.pdf", { NativeOfficeFixtures.pdf(withText: true) }),
        ]
        var files: [URL] = []
        for (name, make) in makers {
            let p = sandbox.appendingPathComponent(name)
            try make().write(to: p)
            files.append(p)
        }
        // ⛔ 对照组：证明这些文件按旧逻辑（字节解码）确实会产生乱码
        let oldStyle = String(decoding: try Data(contentsOf: files[0]).prefix(200), as: UTF8.self)
        XCTAssertTrue(oldStyle.contains("\u{FFFD}") || oldStyle.contains("PK"),
                      String(describing: oldStyle.prefix(60)))
        for p in files {
            let r = extract(p)
            let c = r.content
            XCTAssertFalse(c.contains("PK\u{03}\u{04}"),
                           "\(p.lastPathComponent) 含 zip 魔数: \(String(describing: c.prefix(80)))")
            XCTAssertFalse(c.prefix(2000).contains("\u{FFFD}"),
                           "\(p.lastPathComponent) 含替换符: \(String(describing: c.prefix(80)))")
            XCTAssertTrue(r.ok && c.trimmingCharacters(in: .whitespacesAndNewlines).count > 20,
                          "\(p.lastPathComponent) len=\(c.count)")
        }
    }

    // MARK: - T7 返回契约与字节预算

    func testT7_contractAndBudget() async throws {
        let p = sandbox.appendingPathComponent("契约.docx")
        try NativeOfficeFixtures.legalDocx().write(to: p)
        let r = await exec("read_file", ["path": .string(p.path)])
        XCTAssertTrue(Set(["ok", "content", "size"]).isSubset(of: Set(r.keys)),
                      "\(r.keys)")                                                     // required 齐备
        guard case .bool = r["ok"], case .string = r["content"], case .int = r["size"] else {
            return XCTFail("类型错误: \(r.mapValues { "\($0)" })")
        }
        XCTAssertEqual(r["ok"], .bool(true), "\(r)")
        let realSize = try FileManager.default.attributesOfItem(atPath: p.path)[.size] as? Int64
        XCTAssertEqual(r["size"], .int(realSize ?? -1))                                // size 真实字节数
        let rc = r["content"]?.string ?? ""
        XCTAssertGreaterThan(rc.count, 50, String(rc.prefix(120)))                     // content 非空
        // ⛔⛔ 端到端强断言（专守变异1：撤掉 registry 的解析接线 → 落回字节解码乱码）
        XCTAssertTrue(rc.contains("原告：王永斌") && rc.contains("239900元"),
                      String(describing: rc.prefix(120)))                              // 真实正文（非乱码）
        XCTAssertFalse(rc.contains("PK\u{03}\u{04}"),
                       String(describing: rc.prefix(80)))                              // 无 zip 魔数
        XCTAssertFalse(rc.prefix(2000).contains("\u{FFFD}"),
                       String(describing: rc.prefix(80)))                              // 无替换符
        XCTAssertTrue(rc.contains("已解析"), String(describing: rc.prefix(80)))        // 解析头部标记

        // 预算收紧 → 必须截断且总长受控，不得超预算
        let small = extract(p, budget: 200)
        XCTAssertEqual(small.truncated, true, "\(String(describing: small.truncated))")
        XCTAssertLessThanOrEqual(small.content.utf8.count, 200 + 60,
                                 "\(small.content.utf8.count)")
        XCTAssertTrue(small.content.contains("已截断"), String(small.content.suffix(80)))
    }

    // MARK: - T8 异常路径：不得拖垮 read_file

    func testT8_errorPaths() async throws {
        // 扩展名是 docx 但内容是垃圾 → BadZipFile 等价分支必须被捕获
        let bad = sandbox.appendingPathComponent("坏文件.docx")
        try "这不是一个真正的 docx，只是扩展名叫 docx".write(to: bad, atomically: false,
                                                            encoding: .utf8)
        let r = extract(bad)
        XCTAssertFalse(r.ok, "\(r)")                                                   // ok=False 而非抛异常
        XCTAssertTrue(r.content.contains("不是有效的") || r.content.contains("出错"),
                      String(r.content.prefix(200)))                                   // 损坏原因如实说明
        XCTAssertTrue(r.content.contains("不要编造"), String(r.content.prefix(250)))   // 明确要求不得编造

        // 不支持的扩展名走 unsupported_ext 分支
        let r2 = extract(URL(fileURLWithPath: "/tmp/不存在.xyz"))
        XCTAssertFalse(r2.ok, "\(r2)")

        // read_file 端到端：文件不存在仍走原有错误路径（未回归）
        let r3 = await exec("read_file", ["path": .string(sandbox.appendingPathComponent("没有.docx").path)])
        XCTAssertEqual(r3["ok"], .bool(false), "\(r3)")
        XCTAssertTrue((r3["error"]?.string ?? "").contains("not_a_file"), "\(r3)")
    }

    // MARK: - T9 旧式 .doc：textutil 转换 / 不可用时如实提示

    func testT9_legacyDoc() throws {
        XCTAssertTrue(NativeDocReader.isParseable("a.doc"))          // .doc 纳入可解析范围
        XCTAssertTrue(NativeDocReader.isParseable("a.xls")
                      && NativeDocReader.isParseable("a.ppt"))       // .xls/.ppt 同样纳入
        XCTAssertFalse(NativeDocReader.isParseable("a.txt"))         // .txt 不走解析分支

        // 用 textutil 造一个真实 .doc（系统能力可用时才有意义）
        let src = sandbox.appendingPathComponent("旧文档.txt")
        try "借据\n今借到王永斌人民币贰拾叁万玖仟玖佰元整（¥239900.00）。\n借款人：张元\n"
            .write(to: src, atomically: false, encoding: .utf8)
        let docp = sandbox.appendingPathComponent("旧文档.doc")
        if NativeDocReader.hasTextutil() {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/textutil")
            proc.arguments = ["-convert", "doc", src.path, "-output", docp.path]
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice
            try proc.run()
            proc.waitUntilExit()
        }
        var isDir = ObjCBool(false)
        let docExists = FileManager.default.fileExists(atPath: docp.path, isDirectory: &isDir)
            && !isDir.boolValue
            && ((try? FileManager.default.attributesOfItem(atPath: docp.path)[.size] as? Int64) ?? 0) > 0
        if docExists {
            let r = extract(docp)
            XCTAssertTrue(r.ok, "\(r)")                                              // textutil 转换后成功解析
            XCTAssertTrue(r.content.contains("239900"), String(r.content.prefix(400))) // 中文与金额完好
            XCTAssertTrue(r.content.contains("借据") || r.content.contains("王永斌"),
                          String(r.content.prefix(400)))                             // 正文含借据内容
            // ⛔ 临时目录必须清理（转换产物是中间件，不该留在磁盘）
            let leftovers = (try? FileManager.default.contentsOfDirectory(
                atPath: FileManager.default.temporaryDirectory.path))?
                .filter { $0.hasPrefix("docreader_") } ?? ["<unreadable>"]
            XCTAssertTrue(leftovers.isEmpty, "\(leftovers.prefix(3))")
        } else {
            // 无 textutil 时如实提示另存
            let r = extract(docp)
            XCTAssertTrue(r.content.contains("另存为"), String(r.content.prefix(300)))
        }

        // .xls/.ppt：textutil 不支持 → 必须如实提示，不得假装解析成功
        let fakeXls = sandbox.appendingPathComponent("表格.xls")
        try Data([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]   // OLE 魔数
                 + [UInt8](repeating: UInt8(ascii: "0"), count: 500)).write(to: fakeXls)
        let r2 = extract(fakeXls)
        XCTAssertFalse(r2.ok, "\(r2)")                                             // 不被谎称解析成功
        XCTAssertTrue(r2.content.contains("xlsx"), String(r2.content.prefix(300))) // 提示另存为 .xlsx
    }

    // MARK: - T10 含图为主的文档：不得让模型误判"文件是空的"

    func testT10_imageHeavyDoc() throws {
        let p = sandbox.appendingPathComponent("证据.docx")
        try NativeOfficeFixtures.imageHeavyDocx(imageCount: 25).write(to: p)
        let c = extract(p).content
        XCTAssertTrue(c.contains("25 张"), String(c.prefix(400)))                 // 如实统计内嵌图片数
        XCTAssertTrue(c.contains("图像识别"), String(c.prefix(500)))              // 提示需走图像识别
        XCTAssertTrue(c.contains("不得据本文本臆测") || c.contains("臆测"),
                      String(c.prefix(600)))                                      // 明确禁止臆测图片内容
        // ⛔ 文本极少时也要给出可判断信息，不能只回几十字让模型以为文件空了
        XCTAssertGreaterThan(c.trimmingCharacters(in: .whitespacesAndNewlines).count, 80,
                             "len=\(c.count)")
    }

    // MARK: - T11 回归：纯文本与图片既有行为不变

    func testT11_regression() async throws {
        let txt = sandbox.appendingPathComponent("说明.txt")
        try "这是纯文本文件，内容不应被文档解析影响。239900".write(to: txt, atomically: false,
                                                                  encoding: .utf8)
        let r = await exec("read_file", ["path": .string(txt.path)])
        XCTAssertTrue((r["content"]?.string ?? "").contains("这是纯文本文件"), "\(r)")  // txt 原样返回
        XCTAssertFalse((r["content"]?.string ?? "").contains("已解析"), "\(r)")         // 无解析头部标记
        XCTAssertEqual(r["ok"], .bool(true), "\(r)")

        let img = sandbox.appendingPathComponent("图.png")
        try Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
                 + [UInt8](repeating: 0x61, count: 650)).write(to: img)
        let r2 = await exec("read_file", ["path": .string(img.path)])
        XCTAssertEqual(r2["_kind"], .string("image"), "\(r2)")                          // 仍走 base64 特例
        XCTAssertTrue(r2["image_base64"]?.string?.isEmpty == false, "\(r2)")            // 仍带 base64

        // 大文本软提示（B2/0.4.8）仍生效
        let big = sandbox.appendingPathComponent("大文本.txt")
        try String(repeating: "啊", count: 300000).write(to: big, atomically: false,
                                                         encoding: .utf8)
        let r3 = await exec("read_file", ["path": .string(big.path)])
        XCTAssertTrue((r3["content"]?.string ?? "").contains("大文件提示"), "\(r3)")
    }

    // MARK: - T12 真实用户文档（存在才跑，不存在则跳过不算失败）

    func testT12_realUserFiles() throws {
        let real = [
            "/Users/vetar/Desktop/王永斌证据材料/律师函（方贤君）.docx",
            "/Users/vetar/Desktop/王永斌证据材料/律师函.docx",
            "/Users/vetar/Desktop/王永斌证据材料/证据目录及说明（王永斌）.docx",
            "/Users/vetar/Desktop/王永斌证据材料/证据（王永斌）.docx",
        ]
        var ran = 0
        for f in real {
            guard FileManager.default.fileExists(atPath: f) else { continue }
            ran += 1
            let r = NativeDocReader.extract(path: f, budget: NativeToolRegistry.maxReadBytes)
            let c = r.content
            XCTAssertTrue(r.ok, "\(f): \(r.content)")                                   // 解析成功
            XCTAssertFalse(c.contains("PK\u{03}\u{04}")
                           || c.prefix(2000).contains("\u{FFFD}"),
                           "\(f) 有乱码: \(String(describing: c.prefix(80)))")           // 无乱码
            XCTAssertGreaterThan(c.trimmingCharacters(in: .whitespacesAndNewlines).count,
                                 60, "\(f) len=\(c.count)")                             // 实质内容
        }
        if ran == 0 {
            throw XCTSkip("真实文档不在本机，跳过（不计失败）")
        }
    }
}
