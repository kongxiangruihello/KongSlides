import Foundation
import AppKit
import PDFKit
import XCTest
@testable import KongSlides

final class CompatibilityRecoveryTests: XCTestCase {
    func testListsApplyAtCaretAndNumberNewParagraphs() throws {
        var object = SlideObject(text: "标题\n第一个\n原有第二个", fontSize: 24)
        object.toggleList(in: [3..<3], numbered: true)
        object.toggleList(in: [7..<7], numbered: true)
        XCTAssertEqual(object.paragraphStyles.map { $0.bullet?.marker }, [nil, "1.", "2."])

        object.replaceText(with: "标题\n第一个\n新增\n原有第二个")
        XCTAssertEqual(object.paragraphStyles.map { $0.bullet?.marker }, [nil, "1.", "2.", "3."])
        XCTAssertEqual(object.text, "标题\n第一个\n新增\n原有第二个")

        let display = SlideText.editableText(object, scale: 1)
        let listed = try XCTUnwrap(display.attribute(.paragraphStyle, at: 3, effectiveRange: nil) as? NSParagraphStyle)
        let plain = try XCTUnwrap(display.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertGreaterThan(listed.firstLineHeadIndent, plain.firstLineHeadIndent)
        XCTAssertEqual(display.string, object.text)

        object.toggleList(in: [3..<6], numbered: false)
        XCTAssertEqual(object.paragraphStyles[1].bullet, .symbol("•"))
        object.toggleList(in: [3..<6], numbered: false)
        XCTAssertNil(object.paragraphStyles[1].bullet)

        var empty = SlideObject(text: "现有一项")
        empty.toggleList(in: [], numbered: true)
        empty.replaceText(with: "现有一项\n")
        XCTAssertEqual(empty.paragraphIndices(in: [5..<5]), [1])
        XCTAssertEqual(empty.paragraphStyles.map { $0.bullet?.marker }, ["1.", "2."])
    }

    func testNativeCanvasAndTextRunsRoundTripThroughPPTX() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }

        let object = SlideObject(x: 20, y: 100, width: 580, text: "經學史①", fontSize: 24,
            textRuns: [
                SlideTextRun(start: 0, length: 3, size: 24, bold: true, color: "A12345", fontName: "Songti SC"),
                SlideTextRun(start: 3, length: 1, size: 12, bold: false, color: "123ABC", fontName: "Songti SC", baseline: 0.3)
            ])
        let deck = Deck(slides: [Slide(speakerNotes: "教師講稿", objects: [object])], canvas: .standard)
        let source = folder.appendingPathComponent("classic.pptx")
        try PowerPoint.write(deck, to: source)
        let reopened = try PowerPoint.read(source, prepareImage: { $0 }).deck
        XCTAssertEqual(reopened.pageCanvas.width, 720, accuracy: 0.001)
        XCTAssertEqual(reopened.pageCanvas.height, 540, accuracy: 0.001)
        XCTAssertEqual(reopened.slides.first?.objects.first?.text, object.text)
        XCTAssertEqual(reopened.slides.first?.objects.first?.textRuns, object.textRuns)
        XCTAssertEqual(reopened.slides.first?.speakerNotes, "教師講稿")
        let widescreen = reopened.fitted(to: .widescreen)
        XCTAssertEqual(widescreen.slides[0].objects[0].x, 140, accuracy: 0.001)
        let projection = folder.appendingPathComponent("projection.pdf")
        try SlideDrawing.pdf(reopened, to: projection)
        let page = try XCTUnwrap(PDFDocument(url: projection)?.page(at: 0))
        XCTAssertEqual(page.bounds(for: .mediaBox).width, 720, accuracy: 0.1)
        XCTAssertEqual(page.bounds(for: .mediaBox).height, 540, accuracy: 0.1)
    }

    func testRecoveryCopyPreservesLongDeckAndKeepsNewestSnapshot() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let asset = UUID()
        let image = Data([1, 2, 3])
        var deck = Deck(slides: (1...100).map { index in
            Slide(speakerNotes: "第 \(index) 頁講稿", objects: [SlideObject(kind: .image, imageID: asset)])
        }, images: [asset: image], canvas: .standard)
        let id = UUID()
        try RecoveryFiles.write(.init(savedAt: Date(timeIntervalSince1970: 100), name: "經學史", deck: deck), id: id, in: directory)
        deck.slides[99].speakerNotes = "第100頁修訂"
        try RecoveryFiles.write(.init(savedAt: Date(timeIntervalSince1970: 200), name: "經學史", deck: deck), id: id, in: directory)
        let entries = RecoveryFiles.entries(in: directory)
        XCTAssertEqual(entries.count, 1)
        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry.savedAt, Date(timeIntervalSince1970: 200))
        XCTAssertEqual(try RecoveryFiles.read(entry), deck)
        try RecoveryFiles.remove(id, in: directory)
        XCTAssertTrue(RecoveryFiles.entries(in: directory).isEmpty)
    }

    func testEditingMixedTextRetainsStylesAfterAUnicodeInsertion() {
        var object = SlideObject(text: "甲乙丙", textRuns: [
            SlideTextRun(start: 0, length: 2, size: 24, bold: true, color: "112233"),
            SlideTextRun(start: 2, length: 1, size: 12, bold: false, color: "445566")
        ])
        object.replaceText(with: "甲𠮷乙丙")
        XCTAssertTrue(object.validTextRuns)
        XCTAssertEqual(object.textRuns?.map(\.start), [0, 4])
        XCTAssertEqual(object.textRuns?.map(\.length), [4, 1])
    }

    func testToolbarStylesRoundTripThroughNativeAndPowerPoint() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }

        var object = SlideObject(text: "甲𠮷ß\n第二段", fontSize: 24)
        let character = SlideCharacterStyle(italic: true, underline: true, strikethrough: true,
                                            highlight: "FFE766", spacing: 1.5)
        object.formatCharacters(in: [1..<4]) {
            $0.fontName = "Arial"
            $0.characterStyle = character
            $0.baseline = 0.3
            $0.size = 13.5
        }
        object.changeLetterCase(in: [1..<4], uppercase: true)
        object.formatParagraphs(in: [0..<5]) { _, paragraph in
            paragraph.alignment = .distributed
            paragraph.bullet = .numbered(1, "arabicPeriod")
            paragraph.left = 16
            paragraph.lineMultiple = 1.5
        }
        XCTAssertEqual(object.text, "甲𠮷SS\n第二段")
        XCTAssertEqual(object.textRuns?.first?.start, 1)
        XCTAssertEqual(object.textRuns?.first?.length, 4)
        XCTAssertEqual(object.paragraphStyles[1], .init())
        XCTAssertTrue(object.validTextRuns)
        let deck = Deck(slides: [Slide(objects: [object])])
        let native = folder.appendingPathComponent("格式.kongslides")
        try SlidesDocument(deck: deck).writeNative(to: native)
        XCTAssertEqual(try SlidesDocument.readNative(native).deck, deck)
        let pptx = folder.appendingPathComponent("格式.pptx")
        try PowerPoint.write(deck, to: pptx)
        let reopened = try PowerPoint.read(pptx, prepareImage: { $0 }).deck
        let imported = try XCTUnwrap(reopened.slides.first?.objects.first)
        XCTAssertEqual(imported.text, object.text)
        XCTAssertEqual(imported.formattingStyles(in: [1..<5]).first?.characterStyle, character)
        XCTAssertEqual(imported.formattingStyles(in: [1..<5]).first?.size, 13.5)
        XCTAssertEqual(imported.formattingStyles(in: [1..<5]).first?.baseline, 0.3)
        XCTAssertEqual(imported.paragraphStyles.first, object.paragraphStyles.first)
        XCTAssertNil(imported.formattingStyles(in: [0..<1]).first?.characterStyle)
    }
}
