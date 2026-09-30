//
//  NativeToolOfficeTests.swift
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

//  把 /Users/vetar/Desktop/beta/subagent/sidecar/tools/test_office_io.py（460 行，
//  ⛔ 只读行为规格源）逐条翻译成 XCTest。语义以 Python 源码为准。
//
//  翻译清单（全 27 条，全翻）：
//    D1a docx 解析            → testD1a_docxParse
//    D1b xlsx 解析            → testD1b_xlsxParse
//    D1c pdf 空白页           → testD1c_pdfBlankPage（⚠️ 语义映射见用例注释）
//    D2  pptx 解析含标题/正文 → testD2_pptxParse（a/b/c 三断言）
//    D3a docx 生成            → testD3a_createDocx
//    D3b xlsx 生成            → testD3b_createXlsx
//    D3c pptx 生成            → testD3c_createPptx
//    D3d md 生成              → testD3d_createMd
//    D3e content 非对象报错   → testD3e_contentNotObjectRejected
//    D3f 未知类型报错         → testD3f_unknownTypeRejected
//    D4a/b/c 生成→解析闭环    → testD4_roundtrip
//    D5a/b docx 分页块        → testD5ab_docxPageBreak
//    D5c md 分页标记          → testD5c_mdPageBreak
//    D6a~g image 块尺寸       → testD6a~testD6g（EMU 读回 wp:extent）
//    D6h _to_pos_float 语义   → testD6h_toPosFloat
//    D7a extract_docx_style   → testD7a_extractDocxStyleStructured
//    D7b~h reference 套用六项 → testD7b_toD7h_referenceStyleApplied
//    D7i 缺省回退默认         → testD7i_defaultStyleWithoutReference
//    D7j reference 不存在容错 → testD7j_missingReferenceFallback
//    D7k reference 非 docx    → testD7k_nonDocxReferenceIgnored
//    D7l md+reference 忽略    → testD7l_mdIgnoresReference
//    交叉校验夹具             → testXVal_DumpFixturesForPythonReadback
//      （create_document 产物落 /tmp/p2w3b_xval/，由 managed python 的
//        python-docx/openpyxl/python-pptx 回读验证——阶段汇报「交叉校验」）
//
//  ⚠️VERIFY 未翻清单：
//    ① MUTATE=1|2|3 变异注入机制（Python 运行时改写 doc_writer/doc_reader 模块源码
//      + importlib.reload 的测试有效性自证手段）。Swift 静态编译语言无运行时改写并
//      热加载模块的等价物，无法逐字翻译；其意图（断言必须真正绑定修复）由 D7 六项
//      格式断言直接读回生成物 OOXML 部件承担——若 writeDocx 的参考格式套用被撤掉，
//      testD7b_toD7h 六项即红，无需变异机制佐证。
//    ② D1c：Python parse_attachment 对无文本层 PDF 返回 (None, "pdf")；原生
//      NativeDocReader.extract 契约无 None 语义，按 doc_reader 规格（T5 口径）表现为
//      ok=true + 「无可提取文本」占位提示。用例按后者断言并在此标注。
//
//  隔离纪律：全部 mktemp 临时目录沙盒；样本全部纯 Swift 构造（不依赖 python）。
//

import XCTest
import VetarOOXML
@testable import VetarAINative

// MARK: - 纯 Swift 样本构造（Python _mk_* / _make_* 等价物；doc_reader 套件共用）

enum NativeOfficeFixtures {

    /// 800×400 假 PNG（宽高比恒 2.00）：PNG 签名 + IHDR 宽高字段。
    /// ImageSize.sniff 只读头部 24 字节，嵌入 docx 不要求像素数据合法。
    static var png800x400: Data {
        Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,   // 签名
              0x00, 0x00, 0x00, 0x0D,                            // IHDR 长度
              0x49, 0x48, 0x44, 0x52,                            // "IHDR"
              0x00, 0x00, 0x03, 0x20,                            // width  = 800
              0x00, 0x00, 0x01, 0x90,                            // height = 400
              0x08, 0x06, 0x00, 0x00, 0x00,                      // bitdepth/colortype/...
              0x00, 0x00, 0x00, 0x00])                           // CRC（占位）
    }

    /// Python _mk_docx：单段 "测试段落内容"。
    static func simpleDocx() throws -> Data {
        var b = DocXBuilder()
        b.addParagraph("测试段落内容")
        return try b.data()
    }

    /// Python _mk_xlsx：A1="数据单元格"。
    static func simpleXlsx() throws -> Data {
        var b = XlsxBuilder()
        b.addSheet(name: "Sheet1", rows: [[.string("数据单元格")]])
        return try b.data()
    }

    /// Python _mk_pptx：标题 "测试标题" + 正文 "测试正文"。
    static func simplePptx() throws -> Data {
        var b = PptxBuilder()
        b.addSlide(.init(title: "测试标题", bullets: ["测试正文"]))
        return try b.data()
    }

    /// Python test_p4 _make_pdf 逐字节等价：结构有效的最小 PDF。
    /// withText=false → 内容流仅画矩形（无文本层，模拟扫描件）。
    static func pdf(withText: Bool) -> Data {
        let textOps = "BT /F1 16 Tf 72 720 Td (Wang Yongbin Loan 239900) Tj ET\n"
            + "BT /F1 16 Tf 72 690 Td (Plaintiff: Wang Yongbin) Tj ET"
        let content = withText ? textOps : "0 0 612 792 re f"
        let objs: [String] = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] "
                + "/Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>",
            "",   // 占位，下面单独拼（含流字节）
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
        ]
        var pdf = Data("%PDF-1.4\n".utf8)
        var offsets: [Int] = []
        for (i, body) in objs.enumerated() {
            offsets.append(pdf.count)
            pdf.append(Data("\(i + 1) 0 obj\n".utf8))
            if i == 3 {
                pdf.append(Data("<< /Length \(content.utf8.count) >>\nstream\n".utf8))
                pdf.append(Data(content.utf8))
                pdf.append(Data("\nendstream".utf8))
            } else {
                pdf.append(Data(body.utf8))
            }
            pdf.append(Data("\nendobj\n".utf8))
        }
        let xref = pdf.count
        pdf.append(Data("xref\n0 \(objs.count + 1)\n0000000000 65535 f \n".utf8))
        for off in offsets {
            pdf.append(Data(String(format: "%010d 00000 n \n", off).utf8))
        }
        pdf.append(Data("trailer\n<< /Size \(objs.count + 1) /Root 1 0 R >>\n".utf8))
        pdf.append(Data("startxref\n\(xref)\n%%EOF\n".utf8))
        return pdf
    }

    /// 手写 OOXML 打 docx 包的公共部件（[Content_Types]/_rels/document.xml）。
    /// extraContentTypes：如 png Default；mediaParts：word/media/* 附加条目。
    static func docxPackage(documentXML: String,
                            extraContentTypes: String = "",
                            mediaParts: [(name: String, data: Data)] = []) throws -> Data {
        let contentTypes = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
        <Default Extension="xml" ContentType="application/xml"/>\(extraContentTypes)\
        <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>\
        </Types>
        """
        let rels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>\
        </Relationships>
        """
        var zip = ZipWriter()
        try zip.addFile(name: "[Content_Types].xml", data: Data(contentTypes.utf8))
        try zip.addFile(name: "_rels/.rels", data: Data(rels.utf8))
        try zip.addFile(name: "word/document.xml", data: Data(documentXML.utf8))
        for m in mediaParts { try zip.addFile(name: m.name, data: m.data) }
        return zip.finalize()
    }

    /// Python test_p4 _make_docx 等价：起诉状（标题 22pt 居中 bold 仿宋；
    /// 原告段 14pt 两端对齐 首行缩进 0.99cm=561twips；表格夹在两段之间；
    /// 页面 A4 纵向，页边距 上下 1440/左右 1800 twips）。
    /// ⛔ 格式全部直挂 run rPr / pPr（python-docx 样本同构），不走样式继承。
    static func legalDocx(withTable: Bool = true) throws -> Data {
        let fangsong = #"<w:rFonts w:ascii="Times New Roman" w:hAnsi="Times New Roman" w:eastAsia="仿宋"/>"#
        var body = """
        <w:p><w:pPr><w:jc w:val="center"/></w:pPr>\
        <w:r><w:rPr>\(fangsong)<w:b/><w:sz w:val="44"/><w:szCs w:val="44"/></w:rPr>\
        <w:t>民事起诉状</w:t></w:r></w:p>
        <w:p><w:pPr><w:jc w:val="both"/><w:ind w:firstLine="561"/></w:pPr>\
        <w:r><w:rPr>\(fangsong)<w:sz w:val="28"/><w:szCs w:val="28"/></w:rPr>\
        <w:t>原告：王永斌，男，汉族，住重庆市渝北区。</w:t></w:r></w:p>
        """
        if withTable {
            body += """
            <w:p><w:r><w:t>诉讼请求如下表所列：</w:t></w:r></w:p>
            <w:tbl>
            <w:tr><w:tc><w:p><w:r><w:t>请求事项</w:t></w:r></w:p></w:tc>\
            <w:tc><w:p><w:r><w:t>金额</w:t></w:r></w:p></w:tc></w:tr>
            <w:tr><w:tc><w:p><w:r><w:t>返还借款本金</w:t></w:r></w:p></w:tc>\
            <w:tc><w:p><w:r><w:t>239900元</w:t></w:r></w:p></w:tc></w:tr>
            <w:tr><w:tc><w:p><w:r><w:t>支付资金占用损失</w:t></w:r></w:p></w:tc>\
            <w:tc><w:p><w:r><w:t>5972元</w:t></w:r></w:p></w:tc></w:tr>
            </w:tbl>
            <w:p><w:r><w:t>事实与理由：被告拖欠设备意向金，经多次催告拒不返还。</w:t></w:r></w:p>
            """
        }
        let doc = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>
        \(body)
        <w:sectPr><w:pgSz w:w="11906" w:h="16838"/>\
        <w:pgMar w:top="1440" w:right="1800" w:bottom="1440" w:left="1800" \
        w:header="720" w:footer="720" w:gutter="0"/></w:sectPr>
        </w:body></w:document>
        """
        return try docxPackage(documentXML: doc)
    }

    /// Python test_p4 _make_xlsx 等价：「借款明细」4 行（B4 公式 =SUM(B2:B3) 无计算缓存）
    /// + 「空工作表」。openpyxl 新建表无缓存 → 公式格只有 <f> 无 <v>。
    static func formulaXlsx() throws -> Data {
        let contentTypes = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
        <Default Extension="xml" ContentType="application/xml"/>\
        <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>\
        </Types>
        """
        let rootRels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>\
        </Relationships>
        """
        let workbook = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" \
        xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">\
        <sheets>\
        <sheet name="借款明细" sheetId="1" r:id="rId1"/>\
        <sheet name="空工作表" sheetId="2" r:id="rId2"/>\
        </sheets></workbook>
        """
        let wbRels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>\
        <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet2.xml"/>\
        </Relationships>
        """
        func cStr(_ ref: String, _ text: String) -> String {
            #"<c r="\#(ref)" t="inlineStr"><is><t>\#(text)</t></is></c>"#
        }
        func cNum(_ ref: String, _ num: String) -> String {
            #"<c r="\#(ref)"><v>\#(num)</v></c>"#
        }
        let sheet1 = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>
        <row r="1">\(cStr("A1", "项目"))\(cStr("B1", "金额"))\(cStr("C1", "日期"))</row>
        <row r="2">\(cStr("A2", "本金"))\(cNum("B2", "239900"))\(cStr("C2", "2023-02-01"))</row>
        <row r="3">\(cStr("A3", "利息"))\(cNum("B3", "5972"))\(cStr("C3", "2026-06-03"))</row>
        <row r="4">\(cStr("A4", "合计"))<c r="B4"><f>SUM(B2:B3)</f></c></row>
        </sheetData></worksheet>
        """
        let sheet2 = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData/></worksheet>
        """
        var zip = ZipWriter()
        try zip.addFile(name: "[Content_Types].xml", data: Data(contentTypes.utf8))
        try zip.addFile(name: "_rels/.rels", data: Data(rootRels.utf8))
        try zip.addFile(name: "xl/workbook.xml", data: Data(workbook.utf8))
        try zip.addFile(name: "xl/_rels/workbook.xml.rels", data: Data(wbRels.utf8))
        try zip.addFile(name: "xl/worksheets/sheet1.xml", data: Data(sheet1.utf8))
        try zip.addFile(name: "xl/worksheets/sheet2.xml", data: Data(sheet2.utf8))
        return zip.finalize()
    }

    /// Python test_p4 _make_pptx 等价：手工 zip（slide2 先写入，验证按页码排序）；
    /// 文本含 &amp; 实体，验证解码顺序。
    static func zipFallbackPptx() throws -> Data {
        let xml = """
        <?xml version="1.0"?>\
        <p:sld xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" \
        xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">\
        <p:cSld><p:spTree><p:sp><p:txBody>\
        <a:p><a:r><a:t>案件汇报</a:t></a:r></a:p>\
        <a:p><a:r><a:t>本金 239900 &amp; 利息 5972</a:t></a:r></a:p>\
        </p:txBody></p:sp></p:spTree></p:cSld></p:sld>
        """
        let xml2 = xml.replacingOccurrences(of: "案件汇报", with: "第二页")
            .replacingOccurrences(of: "本金", with: "备注")
        var zip = ZipWriter()
        try zip.addFile(name: "[Content_Types].xml", data: Data("<?xml version=\"1.0\"?><Types/>".utf8))
        try zip.addFile(name: "ppt/slides/slide2.xml", data: Data(xml2.utf8))   // ⛔ 先写 2 后写 1
        try zip.addFile(name: "ppt/slides/slide1.xml", data: Data(xml.utf8))
        return zip.finalize()
    }

    /// Python test_p4 _make_docx_with_images 等价：一段 "证据材料" + n 张 word/media 假图。
    static func imageHeavyDocx(imageCount n: Int) throws -> Data {
        let doc = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>
        <w:p><w:r><w:t>证据材料</w:t></w:r></w:p>
        <w:sectPr><w:pgSz w:w="11906" w:h="16838"/>\
        <w:pgMar w:top="1440" w:right="1800" w:bottom="1440" w:left="1800"/></w:sectPr>
        </w:body></w:document>
        """
        let fakePng = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
            + Data(repeating: UInt8(ascii: "0"), count: 5000)
        let parts = (1...n).map { (name: "word/media/image\($0).png", data: fakePng) }
        return try docxPackage(documentXML: doc,
                               extraContentTypes: #"<Default Extension="png" ContentType="image/png"/>"#,
                               mediaParts: parts)
    }

    /// Python test_office_io D7 参考 docx 等价：正文=楷体 16pt 右对齐 首行缩进 1.5cm
    /// （850 twips）行距 1.5 倍（line=360 auto）；页边距全 5cm（2835 twips）。
    /// ⛔ 格式直挂 run rPr / pPr（python-docx 参考样本同构，extract_docx_style 消费面）。
    static func refStyleDocx() throws -> Data {
        var paras = ""
        for t in ["参考正文一", "参考正文二", "参考正文三"] {
            paras += """
            <w:p><w:pPr><w:jc w:val="right"/><w:ind w:firstLine="850"/>\
            <w:spacing w:line="360" w:lineRule="auto"/></w:pPr>\
            <w:r><w:rPr><w:rFonts w:eastAsia="楷体"/><w:sz w:val="32"/><w:szCs w:val="32"/></w:rPr>\
            <w:t>\(t)</w:t></w:r></w:p>
            """
        }
        let doc = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>
        \(paras)
        <w:sectPr><w:pgSz w:w="11906" w:h="16838"/>\
        <w:pgMar w:top="2835" w:right="2835" w:bottom="2835" w:left="2835"/></w:sectPr>
        </w:body></w:document>
        """
        return try docxPackage(documentXML: doc)
    }

    /// 读 zip 内件文本（D5b/D7c/d/i 断言用）。
    static func zipMemberText(file: URL, name: String) throws -> String {
        let data = try Data(contentsOf: file)
        let zip = try ZipArchiveReader(data: data)
        return String(decoding: try zip.data(named: name, from: data), as: UTF8.self)
    }

    /// 首个 <wp:extent cx cy/> → (cm, cm)（Python inline_shapes[0] EMU→cm 等价）。
    static func firstExtentCm(file: URL) throws -> (w: Double, h: Double)? {
        let xml = try zipMemberText(file: file, name: "word/document.xml")
        let pat = #"<wp:extent cx="(\d+)" cy="(\d+)"/>"#
        guard let re = try? NSRegularExpression(pattern: pat),
              let m = re.firstMatch(in: xml, range: NSRange(xml.startIndex..., in: xml)),
              let r1 = Range(m.range(at: 1), in: xml),
              let r2 = Range(m.range(at: 2), in: xml),
              let cx = Double(xml[r1]), let cy = Double(xml[r2]) else { return nil }
        return (cx / 360000.0, cy / 360000.0)
    }
}

// MARK: - 测试体

final class NativeToolOfficeTests: XCTestCase {

    private var tmp: URL!
    private var sandbox: URL!
    private var context: NativeToolContext!

    override func setUp() {
        super.setUp()
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("w3boffice_\(UUID().uuidString)")
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

    // MARK: - D1 四种输入解析（Python parse_attachment → NativeDocReader.extract）

    func testD1a_docxParse() throws {
        let f = sandbox.appendingPathComponent("a.docx")
        try NativeOfficeFixtures.simpleDocx().write(to: f)
        let r = NativeDocReader.extract(path: f.path, budget: NativeToolRegistry.maxReadBytes)
        XCTAssertEqual(r.parseKind, "docx")
        XCTAssertTrue(r.ok, r.content)
        XCTAssertTrue(r.content.contains("测试段落内容"), r.content)
    }

    func testD1b_xlsxParse() throws {
        let f = sandbox.appendingPathComponent("c.xlsx")
        try NativeOfficeFixtures.simpleXlsx().write(to: f)
        let r = NativeDocReader.extract(path: f.path, budget: NativeToolRegistry.maxReadBytes)
        XCTAssertEqual(r.parseKind, "xlsx")
        XCTAssertTrue(r.ok, r.content)
        XCTAssertTrue(r.content.contains("数据单元格"), r.content)
    }

    /// ⚠️VERIFY 语义映射：Python 断言 parse_attachment 空 PDF → (None, "pdf")（无文本
    /// 返回 None 不报错）；原生 extract 无 None 语义——按 doc_reader T5 口径断言
    /// ok=true + 如实占位提示「无可提取文本」。
    func testD1c_pdfBlankPage() throws {
        let f = sandbox.appendingPathComponent("d.pdf")
        try NativeOfficeFixtures.pdf(withText: false).write(to: f)
        let r = NativeDocReader.extract(path: f.path, budget: NativeToolRegistry.maxReadBytes)
        XCTAssertEqual(r.parseKind, "pdf")
        XCTAssertTrue(r.ok, r.content)   // 不报错
        XCTAssertTrue(r.content.contains("无可提取文本"), r.content)
    }

    // MARK: - D2 pptx 解析（含标题/正文）

    func testD2_pptxParse() throws {
        let f = sandbox.appendingPathComponent("b.pptx")
        try NativeOfficeFixtures.simplePptx().write(to: f)
        let r = NativeDocReader.extract(path: f.path, budget: NativeToolRegistry.maxReadBytes)
        XCTAssertEqual(r.parseKind, "pptx")                              // D2a kind
        XCTAssertTrue(r.content.contains("测试标题"), r.content)          // D2b 标题
        XCTAssertTrue(r.content.contains("测试正文"), r.content)          // D2c 正文
    }

    // MARK: - D3 create_document 四种类型端到端生成 + 反例

    func testD3a_createDocx() async {
        let r = await exec("create_document", [
            "path": .string("报告.docx"),
            "content": .object(["title": .string("T"), "blocks": .array([
                .object(["type": .string("paragraph"), "text": .string("正文")]),
                .object(["type": .string("table"),
                         "rows": .array([.array([.string("a"), .string("b")]),
                                         .array([.string("1"), .string("2")])])]),
            ])]),
        ])
        XCTAssertEqual(r["ok"], .bool(true), "\(r)")
    }

    func testD3b_createXlsx() async {
        let r = await exec("create_document", [
            "path": .string("数据.xlsx"),
            "content": .object(["sheets": .array([
                .object(["name": .string("S"),
                         "rows": .array([.array([.string("月份"), .string("金额")]),
                                         .array([.string("1月"), .string("100")])])]),
            ])]),
        ])
        XCTAssertEqual(r["ok"], .bool(true), "\(r)")
    }

    func testD3c_createPptx() async {
        let r = await exec("create_document", [
            "path": .string("幻灯片.pptx"),
            "content": .object(["slides": .array([
                .object(["title": .string("封面")]),
                .object(["title": .string("页2"),
                         "bullets": .array([.string("要点")])]),
            ])]),
        ])
        XCTAssertEqual(r["ok"], .bool(true), "\(r)")
    }

    func testD3d_createMd() async {
        let r = await exec("create_document", [
            "path": .string("总结.md"),
            "content": .object(["title": .string("总结"), "blocks": .array([
                .object(["type": .string("paragraph"), "text": .string("正文")]),
            ])]),
        ])
        XCTAssertEqual(r["ok"], .bool(true), "\(r)")
    }

    func testD3e_contentNotObjectRejected() async {
        let r = await exec("create_document", ["path": .string("x.docx"),
                                               "content": .string("纯文本")])
        XCTAssertEqual(r["ok"], .bool(false), "\(r)")
    }

    func testD3f_unknownTypeRejected() async {
        let r = await exec("create_document", ["path": .string("y.xyz"),
                                               "content": .object(["title": .string("t")])])
        XCTAssertEqual(r["ok"], .bool(false), "\(r)")
    }

    // MARK: - D4 闭环：生成的文件可被解析器读回

    func testD4_roundtrip() async throws {
        // 生成（与 D3 同契约）
        let r1 = await exec("create_document", [
            "path": .string("报告.docx"),
            "content": .object(["title": .string("T"), "blocks": .array([
                .object(["type": .string("paragraph"), "text": .string("正文")]),
                .object(["type": .string("table"),
                         "rows": .array([.array([.string("a"), .string("b")]),
                                         .array([.string("1"), .string("2")])])]),
            ])]),
        ])
        let r2 = await exec("create_document", [
            "path": .string("数据.xlsx"),
            "content": .object(["sheets": .array([
                .object(["name": .string("S"),
                         "rows": .array([.array([.string("月份"), .string("金额")]),
                                         .array([.string("1月"), .string("100")])])]),
            ])]),
        ])
        let r3 = await exec("create_document", [
            "path": .string("幻灯片.pptx"),
            "content": .object(["slides": .array([
                .object(["title": .string("封面")]),
                .object(["title": .string("页2"),
                         "bullets": .array([.string("要点")])]),
            ])]),
        ])
        XCTAssertEqual(r1["ok"], .bool(true), "\(r1)")
        XCTAssertEqual(r2["ok"], .bool(true), "\(r2)")
        XCTAssertEqual(r3["ok"], .bool(true), "\(r3)")

        // D4a 生成的 docx 可解析且含正文
        let d = NativeDocReader.extract(path: sandbox.appendingPathComponent("报告.docx").path,
                                        budget: NativeToolRegistry.maxReadBytes)
        XCTAssertEqual(d.parseKind, "docx")
        XCTAssertTrue(d.ok && d.content.contains("正文"), d.content)

        // D4b 生成的 xlsx 可解析且含 100（"100" 数字字符串入格 → 数值读回 "100.0"，含 "100"）
        let x = NativeDocReader.extract(path: sandbox.appendingPathComponent("数据.xlsx").path,
                                        budget: NativeToolRegistry.maxReadBytes)
        XCTAssertEqual(x.parseKind, "xlsx")
        XCTAssertTrue(x.ok && x.content.contains("100"), x.content)

        // D4c 生成的 pptx 可解析且含要点
        let p = NativeDocReader.extract(path: sandbox.appendingPathComponent("幻灯片.pptx").path,
                                        budget: NativeToolRegistry.maxReadBytes)
        XCTAssertEqual(p.parseKind, "pptx")
        XCTAssertTrue(p.ok && p.content.contains("要点"), p.content)
    }

    // MARK: - D5 page_break 分页块

    func testD5ab_docxPageBreak() async throws {
        let r = await exec("create_document", [
            "path": .string("证据.docx"),
            "content": .object(["title": .string("证据"), "blocks": .array([
                .object(["type": .string("heading"), "level": .int(2),
                         "text": .string("证据一 借据")]),
                .object(["type": .string("paragraph"), "text": .string("借据内容")]),
                .object(["type": .string("page_break")]),
                .object(["type": .string("heading"), "level": .int(2),
                         "text": .string("证据二 转账记录")]),
                .object(["type": .string("paragraph"), "text": .string("转账内容")]),
            ])]),
        ])
        XCTAssertEqual(r["ok"], .bool(true), "\(r)")   // D5a 生成成功
        // D5b 含分页符（python-docx run xml 含 "page"+"w:br" 的等价：document.xml 直查）
        let xml = try NativeOfficeFixtures.zipMemberText(
            file: sandbox.appendingPathComponent("证据.docx"), name: "word/document.xml")
        let breaks = xml.components(separatedBy: "<w:br w:type=\"page\"/>").count - 1
        XCTAssertGreaterThanOrEqual(breaks, 1, xml)
    }

    func testD5c_mdPageBreak() async throws {
        let r = await exec("create_document", [
            "path": .string("证据.md"),
            "content": .object(["blocks": .array([
                .object(["type": .string("paragraph"), "text": .string("证据一")]),
                .object(["type": .string("page_break")]),
                .object(["type": .string("paragraph"), "text": .string("证据二")]),
            ])]),
        ])
        XCTAssertEqual(r["ok"], .bool(true), "\(r)")
        let md = try String(contentsOf: sandbox.appendingPathComponent("证据.md"),
                            encoding: .utf8)
        XCTAssertTrue(md.contains("---"), md)
    }

    // MARK: - D6 image 块尺寸（0.4.12 A7：单维按比例，双维显式拉伸）

    /// 生成 img_<name>.docx（单 image 块，字段由 sizeFields 给出），读回首图 (w,h) cm。
    private func imgDocx(_ name: String, png: URL,
                         _ sizeFields: [String: JSONValue]) async throws -> (Double, Double) {
        var block: [String: JSONValue] = ["type": .string("image")]
        for (k, v) in sizeFields { block[k] = v }
        let r = await exec("create_document", [
            "path": .string("img_\(name).docx"),
            "content": .object(["title": .string("T"),
                                "blocks": .array([.object(block)])]),
        ])
        XCTAssertEqual(r["ok"], .bool(true), "\(name) 生成失败: \(r)")
        guard let wh = try NativeOfficeFixtures.firstExtentCm(
            file: sandbox.appendingPathComponent("img_\(name).docx")) else {
            XCTFail("\(name) 无 wp:extent（图片未嵌入）")
            return (0, 0)
        }
        return wh
    }

    private func makeProbePng() throws -> URL {
        let img = sandbox.appendingPathComponent("_probe_2to1.png")
        try NativeOfficeFixtures.png800x400.write(to: img)
        return img
    }

    func testD6a_defaultSize() async throws {
        let png = try makeProbePng()
        let (w, h) = try await imgDocx("default", png: png, ["path": .string(png.path)])
        XCTAssertEqual(w, 13.0, accuracy: 0.02, "\(w)x\(h)")   // 默认 A4 正文宽
        XCTAssertEqual(h, 6.5, accuracy: 0.02, "\(w)x\(h)")    // 按 2:1 比例推算
    }

    func testD6b_onlyWidth() async throws {
        let png = try makeProbePng()
        let (w, h) = try await imgDocx("onlyw", png: png,
                                       ["path": .string(png.path), "width_cm": .int(10)])
        XCTAssertEqual(w, 10.0, accuracy: 0.02, "\(w)x\(h)")
        XCTAssertEqual(h, 5.0, accuracy: 0.02, "\(w)x\(h)")    // 高度按比例，不变形
    }

    func testD6c_onlyHeight() async throws {
        let png = try makeProbePng()
        let (w, h) = try await imgDocx("onlyh", png: png,
                                       ["path": .string(png.path), "height_cm": .int(5)])
        XCTAssertEqual(w, 10.0, accuracy: 0.02, "\(w)x\(h)")   // ⭐ 宽度按比例推算
        XCTAssertEqual(h, 5.0, accuracy: 0.02, "\(w)x\(h)")
    }

    func testD6d_bothGiven() async throws {
        let png = try makeProbePng()
        let (w, h) = try await imgDocx("both", png: png,
                                       ["path": .string(png.path),
                                        "width_cm": .int(8), "height_cm": .int(6)])
        XCTAssertEqual(w, 8.0, accuracy: 0.02, "\(w)x\(h)")    // 显式尺寸（拉伸属用户意图）
        XCTAssertEqual(h, 6.0, accuracy: 0.02, "\(w)x\(h)")
    }

    func testD6e_unitString() async throws {
        let png = try makeProbePng()
        let (w, h) = try await imgDocx("unitstr", png: png,
                                       ["path": .string(png.path), "width_cm": .string("12cm")])
        XCTAssertEqual(w, 12.0, accuracy: 0.02, "\(w)x\(h)")   // 带单位字符串可解析
        XCTAssertEqual(h, 6.0, accuracy: 0.02, "\(w)x\(h)")
    }

    func testD6f_invalidValuesFallback() async throws {
        let png = try makeProbePng()
        let (w, h) = try await imgDocx("invalid", png: png,
                                       ["path": .string(png.path),
                                        "width_cm": .string("abc"), "height_cm": .int(-3)])
        XCTAssertEqual(w, 13.0, accuracy: 0.02, "\(w)x\(h)")   // 非法值安全忽略 → 默认
        XCTAssertEqual(h, 6.5, accuracy: 0.02, "\(w)x\(h)")
    }

    func testD6g_gridLayoutHeight() async throws {
        let png = try makeProbePng()
        let (w, h) = try await imgDocx("grid_h", png: png,
                                       ["layout": .string("grid"),
                                        "paths": .array([.string(png.path), .string(png.path)]),
                                        "height_cm": .int(4)])
        XCTAssertEqual(h, 4.0, accuracy: 0.02, "\(w)x\(h)")    // grid 也接受 height_cm
    }

    /// D6h：_to_pos_float 区分「未指定」与「指定 0」（0→None 非 0.0）。
    func testD6h_toPosFloat() {
        XCTAssertNil(NativeDocWriter.toPosFloat(.int(0)))
        XCTAssertNil(NativeDocWriter.toPosFloat(nil))
        XCTAssertNil(NativeDocWriter.toPosFloat(.bool(true)))
        XCTAssertEqual(NativeDocWriter.toPosFloat(.string("7.5")), 7.5)
    }

    // MARK: - D7 写出端按参考文件格式套用（0.4.20 #14）

    private func makeRefDocx() throws -> URL {
        let ref = sandbox.appendingPathComponent("ref_fmt.docx")
        try NativeOfficeFixtures.refStyleDocx().write(to: ref)
        return ref
    }

    /// D7a 提取端：extract_docx_style 返回结构化字段。
    func testD7a_extractDocxStyleStructured() throws {
        let ref = try makeRefDocx()
        let st = NativeDocReader.extractDocxStyle(path: ref.path)
        XCTAssertEqual(st.body?.font, "楷体", "\(String(describing: st.body))")
        XCTAssertEqual(st.body?.sizePt, 16.0)
        XCTAssertEqual(st.body?.alignValue, 2)
        XCTAssertEqual(st.body?.firstLineIndentCm ?? 0, 1.5, accuracy: 0.01)
        XCTAssertEqual(st.body?.lineSpacing, 1.5)
        XCTAssertEqual(st.page?.topCm ?? 0, 5.0, accuracy: 0.01)
    }

    /// D7b~h 写出端端到端：reference_path 套用 → 读回核对六项格式。
    func testD7b_toD7h_referenceStyleApplied() async throws {
        let ref = try makeRefDocx()
        let r = await exec("create_document", [
            "path": .string("out_fmt.docx"),
            "reference_path": .string(ref.path),
            "content": .object(["title": .string("标题"), "blocks": .array([
                .object(["type": .string("paragraph"), "text": .string("新文档正文段落")]),
            ])]),
        ])
        XCTAssertEqual(r["ok"], .bool(true), "\(r)")   // D7b 生成成功

        let out = sandbox.appendingPathComponent("out_fmt.docx")
        // D7c 字体套用（Normal eastAsia=楷体）/ D7d 字号套用（Normal sz=32 半磅=16pt）
        let styles = try NativeOfficeFixtures.zipMemberText(file: out, name: "word/styles.xml")
        XCTAssertTrue(styles.contains(#"w:eastAsia="楷体""#), styles)
        XCTAssertTrue(styles.contains(#"<w:sz w:val="32"/>"#), styles)

        let doc = try DocXReader.load(data: Data(contentsOf: out))
        // D7e 页边距套用（上下左右=5cm；2835twips 读回 5.0009，容差 0.01）
        XCTAssertEqual(doc.page?.topCm ?? 0, 5.0, accuracy: 0.01)
        XCTAssertEqual(doc.page?.leftCm ?? 0, 5.0, accuracy: 0.01)
        // 正文段落（标题除外）
        guard let bp = doc.paragraphs.first(where: { $0.text == "新文档正文段落" }) else {
            return XCTFail("无正文段")
        }
        XCTAssertEqual(bp.alignmentValue, 2)                                   // D7f 右对齐
        XCTAssertEqual(bp.firstLineIndentCm ?? 0, 1.5, accuracy: 0.01)         // D7g 首行缩进
        XCTAssertEqual(bp.lineSpacingMultiple, 1.5)                            // D7h 行距 1.5 倍
    }

    /// D7i 缺省回退：不给 reference_path → 仍是默认（宋体/12pt；向后兼容）。
    func testD7i_defaultStyleWithoutReference() async throws {
        let r = await exec("create_document", [
            "path": .string("out_default.docx"),
            "content": .object(["title": .string("标题"), "blocks": .array([
                .object(["type": .string("paragraph"), "text": .string("默认正文")]),
            ])]),
        ])
        XCTAssertEqual(r["ok"], .bool(true), "\(r)")
        let styles = try NativeOfficeFixtures.zipMemberText(
            file: sandbox.appendingPathComponent("out_default.docx"), name: "word/styles.xml")
        XCTAssertTrue(styles.contains(#"w:eastAsia="宋体""#), styles)
        XCTAssertTrue(styles.contains(#"<w:sz w:val="24"/>"#), styles)   // 24 半磅=12pt
    }

    /// D7j 异常容错：reference_path 指向不存在文件 → 静默回退默认、不报错、仍产出。
    func testD7j_missingReferenceFallback() async throws {
        let r = await exec("create_document", [
            "path": .string("out_badref.docx"),
            "reference_path": .string(sandbox.appendingPathComponent("不存在.docx").path),
            "content": .object(["title": .string("标题"), "blocks": .array([
                .object(["type": .string("paragraph"), "text": .string("正文")]),
            ])]),
        ])
        XCTAssertEqual(r["ok"], .bool(true), "\(r)")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: sandbox.appendingPathComponent("out_badref.docx").path))
    }

    /// D7k 异常容错：reference_path 指向非 docx（.xlsx）→ 忽略参考、仍产出 docx。
    func testD7k_nonDocxReferenceIgnored() async throws {
        // 先造一个真 .xlsx 作"非 docx 参考"
        let r0 = await exec("create_document", [
            "path": .string("数据.xlsx"),
            "content": .object(["sheets": .array([
                .object(["name": .string("S"),
                         "rows": .array([.array([.string("1")])])]),
            ])]),
        ])
        XCTAssertEqual(r0["ok"], .bool(true), "\(r0)")
        let r = await exec("create_document", [
            "path": .string("out_xlsxref.docx"),
            "reference_path": .string(sandbox.appendingPathComponent("数据.xlsx").path),
            "content": .object(["title": .string("标题"), "blocks": .array([
                .object(["type": .string("paragraph"), "text": .string("正文")]),
            ])]),
        ])
        XCTAssertEqual(r["ok"], .bool(true), "\(r)")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: sandbox.appendingPathComponent("out_xlsxref.docx").path))
    }

    /// D7l 仅 docx 生效：md 给 reference_path 不报错（md 无段落排版，安全忽略）。
    func testD7l_mdIgnoresReference() async throws {
        let ref = try makeRefDocx()
        let r = await exec("create_document", [
            "path": .string("out_ref.md"),
            "reference_path": .string(ref.path),
            "content": .object(["title": .string("标题"), "blocks": .array([
                .object(["type": .string("paragraph"), "text": .string("正文")]),
            ])]),
        ])
        XCTAssertEqual(r["ok"], .bool(true), "\(r)")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: sandbox.appendingPathComponent("out_ref.md").path))
    }

    // MARK: - 交叉校验夹具（create_document 产物 → managed python 回读验证）

    /// 把典型产物落盘 /tmp/p2w3b_xval/；随后由阶段脚本用 managed python 的
    /// python-docx/openpyxl/python-pptx 回读断言（跨实现交叉校验，非本测试自证）。
    func testXVal_DumpFixturesForPythonReadback() async throws {
        let dir = URL(fileURLWithPath: "/tmp/p2w3b_xval")
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let png = try makeProbePng()

        // docx：标题/正文/表格/分页/图片（width_cm=10）
        let r1 = await exec("create_document", [
            "path": .string(dir.appendingPathComponent("report.docx").path),
            "content": .object(["title": .string("交叉校验报告"), "blocks": .array([
                .object(["type": .string("heading"), "level": .int(2),
                         "text": .string("第一节")]),
                .object(["type": .string("paragraph"), "text": .string("校验正文段落")]),
                .object(["type": .string("table"),
                         "rows": .array([.array([.string("a"), .string("b")]),
                                         .array([.string("1"), .string("2")])])]),
                .object(["type": .string("page_break")]),
                .object(["type": .string("paragraph"), "text": .string("分页后段落")]),
                .object(["type": .string("image"), "path": .string(png.path),
                         "width_cm": .int(10)]),
            ])]),
        ])
        XCTAssertEqual(r1["ok"], .bool(true), "\(r1)")

        // xlsx：数字字符串自动转数值 + 文本保型
        let r2 = await exec("create_document", [
            "path": .string(dir.appendingPathComponent("data.xlsx").path),
            "content": .object(["sheets": .array([
                .object(["name": .string("SheetA"),
                         "rows": .array([.array([.string("月份"), .string("金额")]),
                                         .array([.string("1月"), .string("100")]),
                                         .array([.string("2月"), .string("200.5")]),
                                         .array([.string("备注"), .string("文本")])])]),
            ])]),
        ])
        XCTAssertEqual(r2["ok"], .bool(true), "\(r2)")

        // pptx：标题/要点/备注两页
        let r3 = await exec("create_document", [
            "path": .string(dir.appendingPathComponent("slides.pptx").path),
            "content": .object(["slides": .array([
                .object(["title": .string("封面"),
                         "bullets": .array([.string("要点一"), .string("要点二")]),
                         "notes": .string("备注内容")]),
                .object(["title": .string("第二页")]),
            ])]),
        ])
        XCTAssertEqual(r3["ok"], .bool(true), "\(r3)")

        for name in ["report.docx", "data.xlsx", "slides.pptx"] {
            let f = dir.appendingPathComponent(name)
            XCTAssertTrue(FileManager.default.fileExists(atPath: f.path), name)
            XCTAssertGreaterThan(
                (try FileManager.default.attributesOfItem(atPath: f.path)[.size] as? Int64) ?? 0,
                0, name)
        }
    }
}
