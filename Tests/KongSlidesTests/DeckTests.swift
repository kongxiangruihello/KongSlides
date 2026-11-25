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
