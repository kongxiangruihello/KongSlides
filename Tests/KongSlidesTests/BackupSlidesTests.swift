import Foundation
import PDFKit
import XCTest
@testable import KongSlides

final class BackupSlidesTests: XCTestCase {
    func testSequentialPlaybackSkipsBackupsInEitherDirection() throws {
        let deck = lesson()
        XCTAssertEqual(deck.firstPresentationIndex(at: 1), 2)
        XCTAssertEqual(deck.firstPresentationIndex(at: 3), 2)
        XCTAssertEqual(deck.presentationIndex(after: 0, step: 1), 2)
        XCTAssertEqual(deck.presentationIndex(after: 2, step: -1), 0)
        XCTAssertNil(deck.presentationIndex(after: 2, step: 1))
        XCTAssertNil(deck.presentationIndex(after: 0, step: -1))
        XCTAssertEqual(try deck.pagesForPDF(includeBackups: false).map(\.offset), [0, 2])
        XCTAssertEqual(try deck.pagesForPDF(includeBackups: true).map(\.offset), [0, 1, 2, 3])
        let allHidden = Deck(slides: deck.slides.filter(\.isBackup))
        XCTAssertNil(allHidden.firstPresentationIndex(at: 0))
        XCTAssertThrowsError(try allHidden.pagesForPDF(includeBackups: false))
    }

    func testNativeAndPowerPointRoundTripKeepBackupsAndSourceTitle() throws {
        let deck = lesson()
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("课堂资料与附录.pptx")
        try PowerPoint.write(deck, to: url)
        let original = try Data(contentsOf: url)
        let imported = try PowerPoint.read(url, prepareImage: { $0 }).deck
        XCTAssertEqual(imported.slides.map(\.isBackup), [false, true, false, true])
        XCTAssertEqual(imported.slides[1].speakerNotes, "PRIVATELECTUREMARKER")
        XCTAssertEqual(imported.importedTitle, "课堂资料与附录")
        XCTAssertEqual(try Data(contentsOf: url), original)
        let native = try JSONEncoder().encode(imported)
        XCTAssertEqual(try JSONDecoder().decode(Deck.self, from: native).validated(), imported)
    }

    func testStudentAndProjectionPDFCanExcludeOrIncludeBackups() throws {
        let deck = lesson()
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }

        for include in [false, true] {
            let slides = root.appendingPathComponent("slides-\(include).pdf")
            try SlideDrawing.pdf(deck, includeBackups: include, to: slides)
            let projection = try XCTUnwrap(PDFDocument(url: slides))
            XCTAssertEqual(projection.pageCount, include ? 4 : 2)
            XCTAssertEqual(text(in: projection).contains("Backup Alpha"), include)

            let students = root.appendingPathComponent("students-\(include).pdf")
            try TeachingPDF.write(deck, format: .studentTwo, includeBackups: include, to: students)
            let handout = try XCTUnwrap(PDFDocument(url: students))
            XCTAssertEqual(handout.pageCount, include ? 2 : 1)
            let studentText = text(in: handout)
            XCTAssertEqual(studentText.contains("Backup Alpha"), include)
            XCTAssertTrue(studentText.contains("Regular Gamma"))
            XCTAssertTrue(studentText.contains("幻灯片 3"))
            XCTAssertFalse(studentText.contains("PRIVATELECTUREMARKER"))
        }

        let teacherURL = root.appendingPathComponent("teacher.pdf")
        try TeachingPDF.write(deck, format: .teacher, to: teacherURL)
        let teacherText = try text(in: XCTUnwrap(PDFDocument(url: teacherURL)))
        XCTAssertTrue(teacherText.contains("Backup Alpha"))
        XCTAssertTrue(teacherText.contains("PRIVATELECTUREMARKER"))
    }

    private func lesson() -> Deck {
        var slides = ["Regular Alpha", "Backup Alpha", "Regular Gamma", "Backup Delta"].map {
            Slide.titleSlide($0, subtitle: "Classroom")
        }
        slides[1].hiddenInShow = true
        slides[1].speakerNotes = "PRIVATELECTUREMARKER"
        slides[3].hiddenInShow = true
        return Deck(slides: slides)
    }

    private func folder() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }

    private func text(in pdf: PDFDocument) -> String {
        (0..<pdf.pageCount).compactMap { pdf.page(at: $0)?.string }.joined(separator: "\n")
    }
}
