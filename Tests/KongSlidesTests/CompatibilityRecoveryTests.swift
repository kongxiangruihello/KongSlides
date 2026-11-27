import Foundation
import PDFKit
import XCTest
@testable import KongSlides

final class CompatibilityRecoveryTests: XCTestCase {
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
}
