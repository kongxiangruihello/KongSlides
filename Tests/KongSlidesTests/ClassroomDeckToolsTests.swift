import AppKit
import PDFKit
import XCTest
@testable import KongSlides

final class ClassroomDeckToolsTests: XCTestCase {
    func testSnapGuideLabelsAndEqualSpacingIntervals() {
        let anchors = [
            CGRect(x: 0, y: 50, width: 20, height: 20),
            CGRect(x: 70, y: 50, width: 20, height: 20)
        ]
        let moving = CGRect(x: 35, y: 105, width: 20, height: 20)
        let equal = CanvasSnap.move(moving, by: CGSize(width: 1, height: 0), anchors: anchors, tolerance: 4)
        XCTAssertEqual(equal.xLabel, "水平等距")
        XCTAssertEqual(equal.xSpacing, [20...35, 55...70])
        XCTAssertEqual(equal.delta.width, 0)

        let aligned = CanvasSnap.move(moving, by: CGSize(width: -34, height: -54), anchors: anchors, tolerance: 4)
        XCTAssertEqual(aligned.xLabel, "左边缘")
        XCTAssertEqual(aligned.delta.width, -35)
        XCTAssertTrue(aligned.xSpacing.isEmpty)
    }

    func testScopedReplacementsKeepStyledUnicodeAndFields() throws {
        var first = Slide.titleSlide("甲𠮷甲", subtitle: "甲乙")
        first.section = "甲章"
        first.speakerNotes = "甲讲稿"
        first.objects[0].formatCharacters(in: [1..<3]) { $0.bold = true }
        let second = Slide.titleSlide("甲未改", subtitle: "")
        var deck = Deck(slides: [first, second])
        let matches = deck.matchingText("甲", fields: [.body, .notes], pages: [first.id])
        XCTAssertEqual(matches.count, 4)
        deck.replace(matches, with: "孔祥")
        XCTAssertEqual(deck.slides[0].objects[0].text, "孔祥𠮷孔祥")
        XCTAssertEqual(deck.slides[0].objects[0].textRuns?.first?.start, 2)
        XCTAssertEqual(deck.slides[0].speakerNotes, "孔祥讲稿")
        XCTAssertEqual(deck.slides[0].section, "甲章")
        XCTAssertEqual(deck.slides[1], second)
    }

    func testFooterOrderStudentPrivacyAndCustomShowSurviveEdits() throws {
        var slides = ["史料", "答案", "讨论"].map { Slide.titleSlide($0, subtitle: "正文") }
        for index in slides.indices { slides[index].section = "第一讲" }
        slides[1].teacherOnly = true
        slides[2].objects[1].teacherOnly = true
        slides[2].speakerNotes = "教师专用讲稿"
        var deck = Deck(slides: slides, courseFooter: .init(course: "经学史"))
        let route = ClassroomShow(name: "讨论版", pages: [slides[2].id, slides[0].id])
        XCTAssertEqual(route.positions(in: deck), [2, 0])
        deck.refreshCourseFooters()
        XCTAssertEqual(deck.slides[2].objects.last?.text, "经学史  ·  第一讲  ·  第 3 页")
        deck.slides.swapAt(0, 2)
        deck.refreshCourseFooters()
        XCTAssertEqual(deck.slides[0].objects.last?.text, "经学史  ·  第一讲  ·  第 1 页")
        XCTAssertEqual(route.positions(in: deck), [0, 2])
        let student = deck.studentCopy(hideTeacherContent: true, includeBackups: false)
        XCTAssertEqual(student.slides.count, 2)
        XCTAssertTrue(student.slides.allSatisfy { $0.speakerNotes.isEmpty })
        XCTAssertFalse(student.slides[0].objects.contains { $0.teacherOnly == true })
    }

    func testReferenceRepairRetainsOriginalAssetsAndCanBeCopied() throws {
        let oldImage = UUID()
        let replacement = UUID()
        var slide = Slide(objects: [SlideObject(kind: .image, imageID: oldImage)])
        ReferencePDF.replace(&slide, with: replacement, size: CGSize(width: 960, height: 540))
        let deck = try Deck(slides: [slide], images: [oldImage: Data([1]), replacement: Data([2])]).validated()
        XCTAssertEqual(deck.images.count, 2)
        let buffer = try SlideClipboard(slides: deck.slides, images: deck.images).validated()
        var destination = Deck()
        let recovered = try XCTUnwrap(buffer.copies(into: &destination).first?.originalPDFPage)
        XCTAssertEqual(destination.images[try XCTUnwrap(recovered.objects.first?.imageID)], Data([1]))
    }

    func testTwoLongDeckPerformanceBaselines() throws {
        var plain = Deck(slides: (1...94).map { Slide.titleSlide("第\($0)页", subtitle: "备课基准") })
        let simple = try ClassroomPerformance.measure(plain)
        XCTAssertTrue(simple.contains("94 页"))
        print("KONGSLIDES_BENCHMARK_94_TEXT\n\(simple)")
        let samples = try (1...24).map { index -> (UUID, Data) in
            let slide = Slide.titleSlide("史料图片 \(index)", subtitle: String(repeating: "史料", count: 30))
            return (UUID(), try XCTUnwrap(ClassroomExport.image(slide, images: [:], canvas: .widescreen, longEdge: 640)))
        }
        plain.images = Dictionary(uniqueKeysWithValues: samples)
        for index in plain.slides.indices {
            plain.slides[index].objects.append(SlideObject(kind: .image, x: 50, y: 360, width: 200, height: 120,
                                                           imageID: samples[index % samples.count].0))
        }
        let illustrated = try ClassroomPerformance.measure(plain)
        XCTAssertTrue(illustrated.contains("24 张素材"))
        print("KONGSLIDES_BENCHMARK_94_IMAGES\n\(illustrated)")
    }
}
