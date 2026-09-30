//
//  PptxBuilder.swift
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

/// pptx 生成器：多页幻灯片，每页标题占位 + 正文占位（项目符号）+ 任意文本框；
/// 含最小可用 slideMaster / slideLayout / theme，保证 Keynote/PowerPoint 可开。
public struct PptxBuilder {

    public struct TextBox {
        /// EMU 单位（914400 EMU = 1 英寸）。
        public let x: Int, y: Int, cx: Int, cy: Int
        public let paragraphs: [String]
        public init(x: Int, y: Int, cx: Int, cy: Int, paragraphs: [String]) {
            self.x = x; self.y = y; self.cx = cx; self.cy = cy; self.paragraphs = paragraphs
        }
    }

    public struct Slide {
        public var title: String
        public var bullets: [String]
        public var textBoxes: [TextBox]
        /// 演讲者备注（doc_writer 契约字段；空串 → 不产 notesSlide part）。
        public var notes: String
        public init(title: String = "", bullets: [String] = [], textBoxes: [TextBox] = [],
                    notes: String = "") {
            self.title = title; self.bullets = bullets; self.textBoxes = textBoxes
            self.notes = notes
        }
    }

    private var slides: [Slide] = []

    /// 16:9 宽屏（EMU）。
    public let slideCX = 12192000
    public let slideCY = 6858000

    public init() {}

    public mutating func addSlide(_ slide: Slide) { slides.append(slide) }
    public mutating func addSlide(title: String, bullets: [String] = []) {
        slides.append(Slide(title: title, bullets: bullets))
    }

    public func data() throws -> Data {
        let list = slides.isEmpty ? [Slide(title: "演示文稿")] : slides
        let withNotes = list.map { !$0.notes.isEmpty }
        let hasNotes = withNotes.contains(true)
        var zip = ZipWriter()
        try zip.addFile(name: "[Content_Types].xml",
                        data: Self.contentTypes(slideCount: list.count, withNotes: withNotes))
        try zip.addFile(name: "_rels/.rels", data: Self.rootRels)
        try zip.addFile(name: "ppt/presentation.xml",
                        data: presentationXML(list, hasNotes: hasNotes))
        try zip.addFile(name: "ppt/_rels/presentation.xml.rels",
                        data: Self.presentationRels(slideCount: list.count, hasNotes: hasNotes))
        try zip.addFile(name: "ppt/theme/theme1.xml", data: Self.themeXML)
        try zip.addFile(name: "ppt/slideMasters/slideMaster1.xml", data: Self.slideMasterXML)
        try zip.addFile(name: "ppt/slideMasters/_rels/slideMaster1.xml.rels", data: Self.slideMasterRels)
        try zip.addFile(name: "ppt/slideLayouts/slideLayout1.xml", data: Self.slideLayoutXML)
        try zip.addFile(name: "ppt/slideLayouts/_rels/slideLayout1.xml.rels", data: Self.slideLayoutRels)
        if hasNotes {
            try zip.addFile(name: "ppt/notesMasters/notesMaster1.xml", data: Self.notesMasterXML)
            try zip.addFile(name: "ppt/notesMasters/_rels/notesMaster1.xml.rels",
                            data: Self.notesMasterRels)
        }
        for (i, s) in list.enumerated() {
            try zip.addFile(name: "ppt/slides/slide\(i + 1).xml", data: slideXML(s))
            try zip.addFile(name: "ppt/slides/_rels/slide\(i + 1).xml.rels",
                            data: Self.slideRels(hasNotes: withNotes[i], slideNumber: i + 1))
            if withNotes[i] {
                try zip.addFile(name: "ppt/notesSlides/notesSlide\(i + 1).xml",
                                data: Self.notesSlideXML(notes: s.notes))
                try zip.addFile(name: "ppt/notesSlides/_rels/notesSlide\(i + 1).xml.rels",
                                data: Self.notesSlideRels(slideNumber: i + 1))
            }
        }
        return zip.finalize()
    }

    public func save(to url: URL) throws {
        try data().write(to: url, options: .atomic)
    }

    // MARK: - slide XML

    private func slideXML(_ slide: Slide) -> Data {
        var nextId = 2
        var shapes = ""

        // 标题占位
        shapes += """
        <p:sp><p:nvSpPr><p:cNvPr id="\(nextId)" name="Title \(nextId)"/>\
        <p:cNvSpPr><a:spLocks noGrp="1"/></p:cNvSpPr><p:nvPr><p:ph type="title"/></p:nvPr></p:nvSpPr>\
        <p:spPr><a:xfrm><a:off x="457200" y="274638"/><a:ext cx="11252200" cy="1143000"/></a:xfrm></p:spPr>\
        <p:txBody><a:bodyPr/><a:lstStyle/><a:p>\
        <a:r><a:rPr lang="zh-CN" dirty="0"/><a:t>\(XMLEscaping.escapeText(slide.title))</a:t></a:r>\
        <a:endParaRPr lang="zh-CN"/></a:p></p:txBody></p:sp>

        """
        nextId += 1

        // 正文占位（项目符号）
        if !slide.bullets.isEmpty {
            var paras = ""
            for b in slide.bullets {
                paras += """
                <a:p><a:pPr marL="342900" indent="-342900"><a:buChar char="•"/></a:pPr>\
                <a:r><a:rPr lang="zh-CN" dirty="0"/><a:t>\(XMLEscaping.escapeText(b))</a:t></a:r>\
                </a:p>

                """
            }
            shapes += """
            <p:sp><p:nvSpPr><p:cNvPr id="\(nextId)" name="Content \(nextId)"/>\
            <p:cNvSpPr><a:spLocks noGrp="1"/></p:cNvSpPr><p:nvPr><p:ph type="body" idx="1"/></p:nvPr></p:nvSpPr>\
            <p:spPr><a:xfrm><a:off x="457200" y="1600200"/><a:ext cx="11252200" cy="4800600"/></a:xfrm></p:spPr>\
            <p:txBody><a:bodyPr/><a:lstStyle/>\(paras)</p:txBody></p:sp>

            """
            nextId += 1
        }

        // 任意文本框
        for tb in slide.textBoxes {
            var paras = ""
            for p in tb.paragraphs {
                paras += "<a:p><a:r><a:rPr lang=\"zh-CN\" dirty=\"0\"/><a:t>\(XMLEscaping.escapeText(p))</a:t></a:r></a:p>"
            }
            shapes += """
            <p:sp><p:nvSpPr><p:cNvPr id="\(nextId)" name="TextBox \(nextId)"/>\
            <p:cNvSpPr txBox="1"/><p:nvPr/></p:nvSpPr>\
            <p:spPr><a:xfrm><a:off x="\(tb.x)" y="\(tb.y)"/><a:ext cx="\(tb.cx)" cy="\(tb.cy)"/></a:xfrm>\
            <a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr>\
            <p:txBody><a:bodyPr wrap="none"/><a:lstStyle/>\(paras)</p:txBody></p:sp>

            """
            nextId += 1
        }

        let x = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:sld xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" \
        xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" \
        xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">\
        <p:cSld><p:spTree>\
        <p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>\
        <p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/>\
        <a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr>\
        \(shapes)</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>
        """
        return Data(x.utf8)
    }

    private func presentationXML(_ slides: [Slide], hasNotes: Bool) -> Data {
        var ids = ""
        for i in 1...slides.count {
            ids += "<p:sldId id=\"\(255 + i)\" r:id=\"rId\(i + 1)\"/>"
        }
        // CT_Presentation 顺序：sldMasterIdLst → notesMasterIdLst → sldIdLst → sldSz/notesSz
        let notesMasterEntry = hasNotes
            ? "<p:notesMasterIdLst><p:notesMasterId r:id=\"rId\(slides.count + 2)\"/></p:notesMasterIdLst>"
            : ""
        let x = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:presentation xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" \
        xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" \
        xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">\
        <p:sldMasterIdLst><p:sldMasterId id="2147483648" r:id="rId1"/></p:sldMasterIdLst>\
        \(notesMasterEntry)<p:sldIdLst>\(ids)</p:sldIdLst>\
        <p:sldSz cx="\(slideCX)" cy="\(slideCY)"/><p:notesSz cx="6858000" cy="9144000"/></p:presentation>
        """
        return Data(x.utf8)
    }

    // MARK: - notes 部件（P2-W3b：doc_writer slides[].notes 契约）

    private static func notesSlideXML(notes: String) -> Data {
        let x = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:notes xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" \
        xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" \
        xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">\
        <p:cSld><p:spTree>\
        <p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>\
        <p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/>\
        <a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr>\
        <p:sp><p:nvSpPr><p:cNvPr id="2" name="Notes Placeholder"/>\
        <p:cNvSpPr><a:spLocks noGrp="1"/></p:cNvSpPr><p:nvPr><p:ph type="body" idx="1"/></p:nvPr></p:nvSpPr>\
        <p:spPr><a:xfrm><a:off x="685800" y="1143000"/><a:ext cx="5486400" cy="6858000"/></a:xfrm></p:spPr>\
        <p:txBody><a:bodyPr/><a:lstStyle/><a:p>\
        <a:r><a:rPr lang="zh-CN" dirty="0"/><a:t>\(XMLEscaping.escapeText(notes))</a:t></a:r>\
        </a:p></p:txBody></p:sp>\
        </p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:notes>
        """
        return Data(x.utf8)
    }

    private static func notesSlideRels(slideNumber: Int) -> Data {
        Data("""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide" Target="../slides/slide\(slideNumber).xml"/>\
        <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/notesMaster" Target="../notesMasters/notesMaster1.xml"/>\
        </Relationships>
        """.utf8)
    }

    private static let notesMasterXML = Data("""
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <p:notesMaster xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" \
    xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" \
    xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">\
    <p:cSld><p:spTree>\
    <p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>\
    <p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/>\
    <a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr></p:spTree></p:cSld>\
    <p:clrMap bg1="lt1" tx1="dk1" bg2="lt2" tx2="dk2" accent1="accent1" accent2="accent2" \
    accent3="accent3" accent4="accent4" accent5="accent5" accent6="accent6" \
    hlink="hlink" folHlink="folHlink"/>\
    <p:notesStyle><a:lvl1pPr><a:defRPr sz="1200"/></a:lvl1pPr></p:notesStyle>\
    </p:notesMaster>
    """.utf8)

    private static let notesMasterRels = Data("""
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
    <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/theme" Target="../theme/theme1.xml"/>\
    </Relationships>
    """.utf8)

    // MARK: - 静态部件

    private static func contentTypes(slideCount: Int, withNotes: [Bool]) -> Data {
        var x = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
        <Default Extension="xml" ContentType="application/xml"/>\
        <Override PartName="/ppt/presentation.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"/>\
        <Override PartName="/ppt/slideMasters/slideMaster1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideMaster+xml"/>\
        <Override PartName="/ppt/slideLayouts/slideLayout1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideLayout+xml"/>\
        <Override PartName="/ppt/theme/theme1.xml" ContentType="application/vnd.openxmlformats-officedocument.theme+xml"/>

        """
        if withNotes.contains(true) {
            x += "<Override PartName=\"/ppt/notesMasters/notesMaster1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.notesMaster+xml\"/>"
        }
        for i in 1...slideCount {
            x += "<Override PartName=\"/ppt/slides/slide\(i).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.slide+xml\"/>"
            if withNotes[i - 1] {
                x += "<Override PartName=\"/ppt/notesSlides/notesSlide\(i).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.notesSlide+xml\"/>"
            }
        }
        x += "</Types>"
        return Data(x.utf8)
    }

    private static let rootRels = Data("""
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
    <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="ppt/presentation.xml"/>\
    </Relationships>
    """.utf8)

    private static func presentationRels(slideCount: Int, hasNotes: Bool) -> Data {
        var x = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster" Target="slideMasters/slideMaster1.xml"/>\
        <Relationship Id="rId\(slideCount + (hasNotes ? 3 : 2))" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/theme" Target="theme/theme1.xml"/>

        """
        if hasNotes {
            x += "<Relationship Id=\"rId\(slideCount + 2)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/notesMaster\" Target=\"notesMasters/notesMaster1.xml\"/>"
        }
        for i in 1...slideCount {
            x += "<Relationship Id=\"rId\(i + 1)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide\" Target=\"slides/slide\(i).xml\"/>"
        }
        x += "</Relationships>"
        return Data(x.utf8)
    }

    private static func slideRels(hasNotes: Bool, slideNumber: Int) -> Data {
        var x = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout" Target="../slideLayouts/slideLayout1.xml"/>
        """
        if hasNotes {
            x += "<Relationship Id=\"rId2\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/notesSlide\" Target=\"../notesSlides/notesSlide\(slideNumber).xml\"/>"
        }
        x += "</Relationships>"
        return Data(x.utf8)
    }

    private static let slideMasterRels = Data("""
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
    <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout" Target="../slideLayouts/slideLayout1.xml"/>\
    <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/theme" Target="../theme/theme1.xml"/>\
    </Relationships>
    """.utf8)

    private static let slideLayoutRels = Data("""
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
    <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster" Target="../slideMasters/slideMaster1.xml"/>\
    </Relationships>
    """.utf8)

    private static let slideLayoutXML = Data("""
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <p:sldLayout xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" \
    xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" \
    xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" \
    type="titleAndObj" preserve="1">\
    <p:cSld name="Title and Content"><p:spTree>\
    <p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>\
    <p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/>\
    <a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr>\
    </p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sldLayout>
    """.utf8)

    private static let slideMasterXML = Data("""
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <p:sldMaster xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" \
    xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" \
    xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">\
    <p:cSld><p:bg><p:bgRef idx="1001"><a:schemeClr val="bg1"/></p:bgRef></p:bg>\
    <p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>\
    <p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/>\
    <a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr></p:spTree></p:cSld>\
    <p:clrMap bg1="lt1" tx1="dk1" bg2="lt2" tx2="dk2" accent1="accent1" accent2="accent2" \
    accent3="accent3" accent4="accent4" accent5="accent5" accent6="accent6" \
    hlink="hlink" folHlink="folHlink"/>\
    <p:sldLayoutIdLst><p:sldLayoutId id="2147483649" r:id="rId1"/></p:sldLayoutIdLst>\
    <p:txStyles><p:titleStyle><a:lvl1pPr><a:defRPr sz="4400" b="1"/></a:lvl1pPr></p:titleStyle>\
    <p:bodyStyle><a:lvl1pPr><a:defRPr sz="2400"/></a:lvl1pPr></p:bodyStyle>\
    <p:otherStyle><a:lvl1pPr><a:defRPr sz="1800"/></a:lvl1pPr></p:otherStyle></p:txStyles>\
    </p:sldMaster>
    """.utf8)

    private static let themeXML = Data("""
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <a:theme xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" name="VetarTheme">\
    <a:themeElements>\
    <a:clrScheme name="Vetar"><a:dk1><a:sysClr val="windowText" lastClr="000000"/></a:dk1>\
    <a:lt1><a:sysClr val="window" lastClr="FFFFFF"/></a:lt1>\
    <a:dk2><a:srgbClr val="1F497D"/></a:dk2><a:lt2><a:srgbClr val="EEECE1"/></a:lt2>\
    <a:accent1><a:srgbClr val="4F81BD"/></a:accent1><a:accent2><a:srgbClr val="C0504D"/></a:accent2>\
    <a:accent3><a:srgbClr val="9BBB59"/></a:accent3><a:accent4><a:srgbClr val="8064A2"/></a:accent4>\
    <a:accent5><a:srgbClr val="4BACC6"/></a:accent5><a:accent6><a:srgbClr val="F79646"/></a:accent6>\
    <a:hlink><a:srgbClr val="0000FF"/></a:hlink><a:folHlink><a:srgbClr val="800080"/></a:folHlink></a:clrScheme>\
    <a:fontScheme name="Vetar"><a:majorFont><a:latin typeface="Helvetica Neue"/>\
    <a:ea typeface="PingFang SC"/><a:cs typeface=""/></a:majorFont>\
    <a:minorFont><a:latin typeface="Helvetica Neue"/><a:ea typeface="PingFang SC"/>\
    <a:cs typeface=""/></a:minorFont></a:fontScheme>\
    <a:fmtScheme name="Vetar">\
    <a:fillStyleLst><a:solidFill><a:schemeClr val="phClr"/></a:solidFill>\
    <a:solidFill><a:schemeClr val="phClr"/></a:solidFill>\
    <a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:fillStyleLst>\
    <a:lnStyleLst><a:ln w="9525"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln>\
    <a:ln w="25400"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln>\
    <a:ln w="38100"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln></a:lnStyleLst>\
    <a:effectStyleLst><a:effectStyle><a:effectLst/></a:effectStyle>\
    <a:effectStyle><a:effectLst/></a:effectStyle>\
    <a:effectStyle><a:effectLst/></a:effectStyle></a:effectStyleLst>\
    <a:bgFillStyleLst><a:solidFill><a:schemeClr val="phClr"/></a:solidFill>\
    <a:solidFill><a:schemeClr val="phClr"/></a:solidFill>\
    <a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:bgFillStyleLst></a:fmtScheme>\
    </a:themeElements></a:theme>
    """.utf8)
}
