import Foundation
import PDFKit
import XCTest
@testable import KongSlides

final class DeckTests: XCTestCase {
    func testClassroomDeckRoundTripAndPDF() throws {
        var deck = Deck()
        deck.slides = (1...100).map { index in
            var slide = Slide.titleSlide("第 \(index) 页", subtitle: "史料引文")
            slide.section = "原典"
            slide.speakerNotes = "第 \(index) 页讲稿"
            return slide
        }
        let saved = try JSONEncoder().encode(deck)
        XCTAssertEqual(try JSONDecoder().decode(Deck.self, from: saved).validated(), deck)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        try SlideDrawing.pdf(deck, to: url)
        let pdf = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertEqual(pdf.pageCount, 100)
        XCTAssertTrue(pdf.page(at: 99)?.string?.contains("100") ?? false)
    }

    func testEditablePowerPointAndNotes() throws {
        var deck = Deck()
        var slide = Slide.titleSlide("礼乐 & 政治 <原文>", subtitle: "第二行")
        slide.speakerNotes = "《论语》\n\n第二段讲稿"
        let imageID = UUID()
        deck.images[imageID] = try XCTUnwrap(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aTioAAAAASUVORK5CYII="))
        let crop = PictureCrop(left: 0.125, top: 0.1, right: 0.025, bottom: 0.15)
        slide.objects.append(SlideObject(kind: .image, width: 100, height: 100, imageID: imageID,
                                         pictureCrop: crop))
        deck.slides = [slide, Slide()]

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("pptx")
        defer { try? FileManager.default.removeItem(at: url) }
        try PowerPoint.write(deck, to: url)

        let presentation = try unzip(url, "ppt/presentation.xml")
        XCTAssertTrue(presentation.contains("rId4"))
        let exportedSlide = try unzip(url, "ppt/slides/slide1.xml")
        XCTAssertTrue(exportedSlide.contains("礼乐 &amp; 政治 &lt;原文&gt;"))
        XCTAssertTrue(exportedSlide.contains("<p:pic>"))
        XCTAssertTrue(exportedSlide.contains("l=\"12500\" t=\"10000\" r=\"2500\" b=\"15000\""))
        let notes = try unzip(url, "ppt/notesSlides/notesSlide1.xml")
        XCTAssertTrue(notes.contains("第二段讲稿"))
        XCTAssertTrue(notes.contains("<p:ph type=\"body\""))
        let relations = try unzip(url, "ppt/slides/_rels/slide1.xml.rels")
        XCTAssertTrue(relations.contains("../media/\(imageID.uuidString).png"))

        let imported = try PowerPoint.read(url, prepareImage: { $0 })
        XCTAssertEqual(imported.deck.slides.count, 2)
        XCTAssertEqual(imported.deck.slides.first?.objects.map(\.kind), [.text, .text, .rectangle, .image])
        XCTAssertEqual(imported.deck.slides.first?.objects.first?.text, "礼乐 & 政治 <原文>")
        XCTAssertEqual(imported.deck.slides.first?.speakerNotes, slide.speakerNotes)
        XCTAssertEqual(imported.deck.images.values.first, deck.images[imageID])
        XCTAssertEqual(imported.deck.slides.first?.objects.last?.pictureCrop, crop)
        XCTAssertEqual(imported.deck.slides.flatMap { $0.importReport?.diagnostics ?? [] }, [])

    }

    func testImportedParagraphsSurvivePPTXAndNativeRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("pptx")
        defer { try? FileManager.default.removeItem(at: url) }
        let layout = SlideTextLayout(
            fontName: "Teaching Fixture Font",
            insets: .init(left: 7, top: 5, right: 7, bottom: 5),
            paragraphs: [
                SlideParagraph(alignment: .center, lineMultiple: 1.5, after: 8),
                SlideParagraph(alignment: .left, lineHeight: 28, left: 32, firstLine: -18, bullet: .symbol("◆")),
                SlideParagraph(alignment: .right, bullet: .numbered(3, "arabicParenR"))
            ]
        )
        let object = SlideObject(width: 600, height: 260, text: "经文与译注\n史料\u{2028}课堂讨论\n第三问",
                                 fontSize: 26, bold: true, textLayout: layout)
        let deck = Deck(slides: [Slide(speakerNotes: "原文导读", objects: [object])])
        try PowerPoint.write(deck, to: url)
        let imported = try PowerPoint.read(url, fontAvailable: { _ in false }, prepareImage: { $0 }).deck
        let slide = try XCTUnwrap(imported.slides.first)
        let text = try XCTUnwrap(slide.objects.first)
        XCTAssertEqual(text.text, object.text)
        XCTAssertEqual(text.textLayout, layout)
        XCTAssertEqual(text.fontSize, 26)
        XCTAssertEqual(slide.speakerNotes, "原文导读")
        XCTAssertEqual(slide.importReport?.diagnostics.map(\.kind), [.font])
        let row = try XCTUnwrap(SlideReviewRow.imported(imported).first)
        XCTAssertEqual(row.slideID, slide.id)
        XCTAssertEqual(row.objectID, text.id)
        XCTAssertEqual(SlideReviewRow.imported(Deck(slides: [Slide(), slide])).first?.page, 2)
        XCTAssertEqual(try JSONDecoder().decode(Deck.self, from: JSONEncoder().encode(imported)).validated(), imported)
    }

    func testEditingImportedParagraphKeepsFollowingFormatting() {
        let title = SlideParagraph(alignment: .center)
        let bullet = SlideParagraph(left: 32, firstLine: -18, bullet: .symbol("◆"))
        let discussion = SlideParagraph(alignment: .right)
        var text = SlideObject(text: "经文\n史料引文\n课堂讨论",
                               textLayout: SlideTextLayout(paragraphs: [title, bullet, discussion]))
        text.replaceText(with: "经文\n史料\n引文\n课堂讨论")
        XCTAssertEqual(text.textLayout?.paragraphs, [title, bullet, bullet, discussion])
        text.replaceText(with: "经文\n史料\n课堂讨论")
        XCTAssertEqual(text.textLayout?.paragraphs, [title, bullet, discussion])
    }

    func testPlaceholderGeometryAndDefaultsComeFromLayout() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: path) }
        let url = path.appendingPathComponent("样本.pptx")
        let package = path.appendingPathComponent("package", isDirectory: true)
        try PowerPoint.write(Deck(slides: [Slide()]), to: url)
        try run("/usr/bin/unzip", ["-q", url.path, "-d", package.path])

        let ns = """
        xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"
        """
        let shape = """
        <p:nvSpPr><p:cNvPr id="2" name="正文"/><p:cNvSpPr/><p:nvPr><p:ph idx="3"/></p:nvPr></p:nvSpPr>
        """
        let page = """
        <p:sld \(ns)><p:cSld><p:spTree><p:sp>\(shape)<p:spPr/><p:txBody><a:bodyPr/>
        <a:p><a:r><a:t>孔子论礼</a:t></a:r></a:p></p:txBody></p:sp>
        <p:graphicFrame><p:nvGraphicFramePr><p:cNvPr id="3" name="统计图"/></p:nvGraphicFramePr></p:graphicFrame>
        </p:spTree></p:cSld></p:sld>
        """
        let layout = """
        <p:sldLayout \(ns)><p:cSld><p:spTree><p:sp>\(shape)
        <p:spPr><a:xfrm><a:off x="1270000" y="1905000"/><a:ext cx="6350000" cy="2540000"/></a:xfrm></p:spPr>
        <p:txBody><a:bodyPr/><a:lstStyle><a:lvl1pPr algn="ctr"><a:lnSpc><a:spcPct val="130000"/></a:lnSpc>
        <a:defRPr sz="3200"><a:ea typeface="Songti SC"/></a:defRPr></a:lvl1pPr></a:lstStyle><a:p/></p:txBody>
        </p:sp></p:spTree></p:cSld></p:sldLayout>
        """
        try page.write(to: package.appendingPathComponent("ppt/slides/slide1.xml"), atomically: true, encoding: .utf8)
        try layout.write(to: package.appendingPathComponent("ppt/slideLayouts/slideLayout1.xml"), atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: url)
        try run("/usr/bin/zip", ["-qr", url.path, "[Content_Types].xml", "_rels", "ppt"], folder: package)
        let imported = try PowerPoint.read(url, prepareImage: { $0 }).deck
        let slide = try XCTUnwrap(imported.slides.first)
        let text = try XCTUnwrap(slide.objects.first)
        XCTAssertEqual(text.frame, CGRect(x: 100, y: 150, width: 500, height: 200))
        XCTAssertEqual(text.fontSize, 32)
        XCTAssertEqual(text.textLayout?.fontName, "Songti SC")
        XCTAssertEqual(text.textLayout?.paragraphs.first?.alignment, .center)
        XCTAssertEqual(text.textLayout?.paragraphs.first?.lineMultiple, 1.3)
        XCTAssertEqual(slide.importReport?.diagnostics.map(\.kind), [.unsupported])
    }

    func testNestedPowerPointGroupsImportAsEditableObjects() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("组合样本.pptx")
        let package = root.appendingPathComponent("package")
        let imageID = UUID()
        let png = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aTioAAAAASUVORK5CYII="))
        let image = SlideObject(kind: .image, x: 20, y: 40, width: 50, height: 30, imageID: imageID)
        let text = SlideObject(x: 15, y: 30, width: 120, height: 45, text: "组合里可编辑的原文", fontSize: 24)
        let source = Deck(slides: [Slide(objects: [image, text])], images: [imageID: png])
        try PowerPoint.write(source, to: url)
        try run("/usr/bin/unzip", ["-q", url.path, "-d", package.path])

        let page = package.appendingPathComponent("ppt/slides/slide1.xml")
        var xml = try String(contentsOf: page, encoding: .utf8)
        let outer = """
        <p:grpSp><p:nvGrpSpPr><p:cNvPr id="20" name="外层组合"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>
        <p:grpSpPr><a:xfrm><a:off x="1270000" y="1016000"/><a:ext cx="5080000" cy="3810000"/>
        <a:chOff x="127000" y="254000"/><a:chExt cx="2540000" cy="1905000"/></a:xfrm></p:grpSpPr>
        """
        let inner = """
        <p:grpSp><p:nvGrpSpPr><p:cNvPr id="21" name="内层组合"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr>
        <p:grpSpPr><a:xfrm rot="1800000"><a:off x="508000" y="762000"/><a:ext cx="1270000" cy="635000"/>
        <a:chOff x="63500" y="127000"/><a:chExt cx="2540000" cy="1270000"/></a:xfrm></p:grpSpPr>
        """
        xml = xml.replacingOccurrences(of: "<p:grpSpPr/>", with: "<p:grpSpPr/>" + outer)
        xml = xml.replacingOccurrences(of: "</p:pic>", with: "</p:pic>" + inner)
        xml = xml.replacingOccurrences(of: "</p:spTree>", with: "</p:grpSp></p:grpSp></p:spTree>")
        try xml.write(to: page, atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: url)
        try run("/usr/bin/zip", ["-qr", url.path, "[Content_Types].xml", "_rels", "ppt"], folder: package)

        let deck = try PowerPoint.read(url, prepareImage: { $0 }).deck
        let slide = try XCTUnwrap(deck.slides.first)
        XCTAssertEqual(slide.objects.map(\.kind), [.image, .text])
        let picture = try XCTUnwrap(slide.objects.first)
        let editable = try XCTUnwrap(slide.objects.last)
        XCTAssertEqual(picture.frame, CGRect(x: 120, y: 120, width: 100, height: 60))
        XCTAssertEqual(editable.frame, CGRect(x: 170, y: 180, width: 120, height: 45))
        XCTAssertEqual(editable.text, text.text)
        XCTAssertEqual(editable.fontSize, 24)
        XCTAssertEqual(deck.images.values.first, png)
        XCTAssertEqual(slide.importReport?.diagnostics.map(\.detail), ["组合「内层组合」的整体旋转或翻转未保留。"])
    }

    func testPowerPointMasterAndLayoutDecorationsRespectSourceAndLayerOrder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("母版样本.pptx")
        let package = root.appendingPathComponent("package")
        let id = UUID()
        let logo = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aTioAAAAASUVORK5CYII="))
        let bodyImage = logo + Data([0])
        let fixture = Deck(slides: [
            Slide(objects: [SlideObject(text: "课程标题"), SlideObject(kind: .image, imageID: id)]),
            Slide(objects: [SlideObject(text: "关闭母版图形")]),
            Slide(objects: [SlideObject(text: "使用本页页脚")])
        ], images: [id: bodyImage])
        try PowerPoint.write(fixture, to: url)
        try run("/usr/bin/unzip", ["-q", url.path, "-d", package.path])
        func update(_ part: String, _ change: (String) -> String) throws {
            let path = package.appendingPathComponent(part)
            try change(String(contentsOf: path, encoding: .utf8)).write(to: path, atomically: true, encoding: .utf8)
        }
        let masterPic = """
        <p:pic><p:nvPicPr><p:cNvPr id="2" name="校徽"/><p:cNvPicPr/><p:nvPr/></p:nvPicPr>
        <p:blipFill><a:blip r:embed="rId2"/></p:blipFill><p:spPr><a:xfrm>
        <a:off x="127000" y="254000"/><a:ext cx="508000" cy="508000"/></a:xfrm></p:spPr></p:pic>
        """
        func text(_ name: String, content: String, id: Int, placeholder: String = "") -> String {
            """
            <p:sp><p:nvSpPr><p:cNvPr id="\(id)" name="\(name)"/><p:cNvSpPr/><p:nvPr>\(placeholder)</p:nvPr></p:nvSpPr>
            <p:spPr><a:xfrm><a:off x="127000" y="6350000"/><a:ext cx="3810000" cy="381000"/></a:xfrm></p:spPr>
            <p:txBody><a:bodyPr/><a:p><a:r><a:rPr sz="1200"/><a:t>\(content)</a:t></a:r></a:p></p:txBody></p:sp>
            """
        }
        let footerPlaceholder = "<p:ph type=\"ftr\" idx=\"9\"/>"
        let prompt = text("标题占位符", content: "单击此处编辑标题", id: 8, placeholder: "<p:ph type=\"title\"/>")
        let footer = text("母版页脚", content: "思想史课程", id: 9, placeholder: footerPlaceholder)
        let layoutDecoration = text("版式字样", content: "教学资料", id: 8)
        try update("ppt/slideMasters/slideMaster1.xml") {
            $0.replacingOccurrences(of: "</p:spTree>", with: masterPic + prompt + footer + "</p:spTree>")
                .replacingOccurrences(of: "</p:sldMaster>", with: "<p:hf ftr=\"1\"/></p:sldMaster>")
        }
        try update("ppt/slideLayouts/slideLayout1.xml") {
            $0.replacingOccurrences(of: "</p:spTree>", with: layoutDecoration + "</p:spTree>")
        }
        try update("ppt/slideMasters/_rels/slideMaster1.xml.rels") {
            $0.replacingOccurrences(of: "Id=\"rId2\"", with: "Id=\"rId99\"")
                .replacingOccurrences(of: "</Relationships>", with: """
                <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="../media/master-logo.png"/>
                </Relationships>
                """)
        }
        try logo.write(to: package.appendingPathComponent("ppt/media/master-logo.png"))
        try update("ppt/slides/slide2.xml") { $0.replacingOccurrences(of: "<p:sld ", with: "<p:sld showMasterSp=\"false\" ") }
        let localFooter = text("本页页脚", content: "本页独有", id: 9, placeholder: footerPlaceholder)
        try update("ppt/slides/slide3.xml") { $0.replacingOccurrences(of: "</p:spTree>", with: localFooter + "</p:spTree>") }
        try FileManager.default.removeItem(at: url)
        try run("/usr/bin/zip", ["-qr", url.path, "[Content_Types].xml", "_rels", "ppt"], folder: package)

        let result = try PowerPoint.read(url, prepareImage: { $0 }).deck
        XCTAssertEqual(result.slides.map(\.title), ["课程标题", "关闭母版图形", "使用本页页脚"])
        let first = result.slides[0]
        XCTAssertEqual(first.objects.map(\.decorationSource), [.master, .master, .layout, nil, nil])
        XCTAssertEqual(first.objects.filter { $0.kind == .text }.map(\.text), ["思想史课程", "教学资料", "课程标题"])
        let firstLogo = try XCTUnwrap(first.objects.first?.imageID)
        let firstBody = try XCTUnwrap(first.objects.last?.imageID)
        XCTAssertEqual(result.images[firstLogo], logo)
        XCTAssertEqual(result.images[firstBody], bodyImage)
        XCTAssertEqual(result.slides[1].objects.map(\.decorationSource), [.layout, nil])
        XCTAssertEqual(result.slides[2].objects.filter { $0.kind == .text }.map(\.text), ["教学资料", "使用本页页脚", "本页独有"])
        XCTAssertEqual(result.slides[2].objects.first?.imageID, firstLogo)
    }

    func testImportReportPrioritizesUnreadablePageAndKeepsReadableSlides() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("部分损坏.pptx")
        let slides = [
            Slide(objects: [SlideObject(text: "仍能读取", textLayout: SlideTextLayout(fontName: "Missing test font"))]),
            Slide(objects: [SlideObject(text: "源页缺失")]),
            Slide(objects: [SlideObject(text: "末页")])
        ]
        try PowerPoint.write(Deck(slides: slides), to: url)
        try run("/usr/bin/zip", ["-dq", url.path, "ppt/slides/slide2.xml"])
        let imported = try PowerPoint.read(url, fontAvailable: { _ in false }, prepareImage: { $0 }).deck
        XCTAssertEqual(imported.slides.count, 3)
        XCTAssertEqual(imported.slides[0].title, "仍能读取")
        XCTAssertEqual(imported.slides[2].title, "末页")
        XCTAssertTrue(imported.slides[1].isBackup)
        let report = SlideReviewRow.imported(imported)
        XCTAssertEqual(report.first?.impact, .pageUnavailable)
        XCTAssertEqual(report.first?.page, 2)
        XCTAssertEqual(report.first?.title, "整页读取失败")
        XCTAssertTrue(report.contains { $0.page == 1 && $0.impact == .appearance })
    }

    func testOlderImportDiagnosticsAreClassifiedWithoutChangingSavedContent() throws {
        let data = Data("""
        [
          {"kind":"font","detail":"本机缺少字体"},
          {"kind":"unsupported","detail":"无法转换源第 2 页"},
          {"kind":"image","detail":"图片无法解码"},
          {"kind":"unsupported","detail":"表格样式已简化","objectID":"7611AD92-63EA-4980-B5A8-2043A719F3C4"}
        ]
        """.utf8)
        let issues = try JSONDecoder().decode([ImportDiagnostic].self, from: data)
        XCTAssertEqual(issues.map(\.impact), [.appearance, .pageUnavailable, .contentMissing, .appearance])
        XCTAssertEqual(issues.last?.title, "部分格式已简化")
        let encoded = try JSONEncoder().encode(issues)
        XCTAssertEqual(try JSONDecoder().decode([ImportDiagnostic].self, from: encoded), issues)
    }

    func testIndexedImportMatchesSystemReaderForNinetyFourSlides() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pptx")
        defer { try? FileManager.default.removeItem(at: url) }
        let slideCount = 94
        let deck = Deck(slides: (1...slideCount).map { page in
            var slide = Slide.titleSlide("第 \(page) 页", subtitle: "中国近现代思想史")
            slide.speakerNotes = "第 \(page) 页讲稿"
            return slide
        })
        try PowerPoint.write(deck, to: url)
        XCTAssertNotNil(PowerPointZipIndex(url: url))
        let clock = ContinuousClock()
        let oldStart = clock.now
        let baseline = try PowerPoint.read(url, useIndexedArchive: false, prepareImage: { $0 }).deck
        let oldTime = clock.now - oldStart
        let newStart = clock.now
        let indexed = try PowerPoint.read(url, prepareImage: { $0 }).deck
        let newTime = clock.now - newStart
        print("PPTX 94-page benchmark: system \(oldTime), indexed \(newTime)")
        XCTAssertEqual(indexed.slides.map(\.title), baseline.slides.map(\.title))
        XCTAssertEqual(indexed.slides.map(\.speakerNotes), baseline.slides.map(\.speakerNotes))
        XCTAssertEqual(indexed.slides.map { $0.objects.map(\.frame) }, baseline.slides.map { $0.objects.map(\.frame) })
        XCTAssertEqual(indexed.slides.count, slideCount)
        XCTAssertLessThan(newTime, oldTime)
    }

    func testPreflightIdentifiesClippingAndPDFUsesSameTextFrame() throws {
        let visible = SlideObject(x: 60, y: 40, width: 340, height: 42, text: "VISIBLE\nHIDDEN", fontSize: 27)
        let clean = SlideObject(x: 60, y: 110, width: 340, height: 95, text: "CLEAN LINE", fontSize: 27)
        let image = SlideObject(kind: .image, x: 930, y: 130, width: 55, height: 45)
        let deck = Deck(slides: [Slide(objects: [visible, clean]), Slide(objects: [image])])
        let rows = SlideReviewRow.preflight(deck)
        XCTAssertEqual(rows.map(\.title), ["文字可能截断", "图片超出画布"])
        XCTAssertEqual(rows.map(\.objectID), [visible.id, image.id])
        XCTAssertEqual(rows.map(\.page), [1, 2])

        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("pdf")
        defer { try? FileManager.default.removeItem(at: file) }
        try SlideDrawing.pdf(deck, to: file)
        let pdf = try XCTUnwrap(PDFDocument(url: file))
        let text = try XCTUnwrap(pdf.page(at: 0)?.string)
        XCTAssertTrue(text.contains("VISIBLE"))
        XCTAssertTrue(text.contains("CLEAN LINE"))
        XCTAssertFalse(text.contains("HIDDEN"))
    }

    private func run(_ path: String, _ args: [String], folder: URL? = nil) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        process.currentDirectoryURL = folder
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    private func unzip(_ url: URL, _ path: String) throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", url.path, path]
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        _ = try XMLDocument(data: data)
        return String(decoding: data, as: UTF8.self)
    }
}
