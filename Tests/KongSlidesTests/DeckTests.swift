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
        slide.objects.append(SlideObject(kind: .image, width: 100, height: 100, imageID: imageID))
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
