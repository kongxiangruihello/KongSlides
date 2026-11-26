import Foundation
import PDFKit
import XCTest
@testable import KongSlides

final class TeachingToolsTests: XCTestCase {
    func testParsesChapterMarkersAndCanMoveParagraphsBeforeGenerating() throws {
        var drafts = try TeachingOutline.parse(TeachingOutline.example, defaultDestination: .projection)
        XCTAssertEqual(drafts.map(\.title), ["《论语》中的礼乐", "人而不仁，如礼何", "课堂讨论"])
        XCTAssertEqual(drafts.last?.section, "从礼仪到礼义")
        XCTAssertTrue(drafts[1].projection.contains("• 礼乐能维持秩序"))
        XCTAssertTrue(drafts[1].notes.contains("资料出处"))
        let quotationIndex = try XCTUnwrap(drafts[1].blocks.firstIndex { $0.text.contains("子曰") })
        drafts[1].blocks[quotationIndex].destination = .notes
        let deck = try TeachingGenerator.generate(drafts, template: .classic)
        XCTAssertTrue(deck.slides[1].speakerNotes.contains("子曰"))
        XCTAssertFalse(deck.slides[1].objects.contains { $0.text.contains("子曰") })
        XCTAssertEqual(deck.slides[1].section, "从礼仪到礼义")
    }

    func testLectureNotesDefaultAndPageSeparator() throws {
        let input = """
        ## 第一节
        第一段解释。

        【投影】课堂问题
        ---
        下一页的讲稿。
        ## 第二节
        """
        let drafts = try TeachingOutline.parse(input, defaultDestination: .notes)
        XCTAssertEqual(drafts.count, 3)
        XCTAssertEqual(drafts[0].projection, "课堂问题")
        XCTAssertEqual(drafts[0].notes, "第一段解释。")
        XCTAssertEqual(drafts[1].notes, "下一页的讲稿。")
        XCTAssertEqual(drafts[2].title, "第二节")
    }

    func testLongProjectionCreatesEditableContinuationPagesWithoutLosingText() throws {
        let longBody = String(repeating: "仁者爱人，礼者敬人。", count: 125)
        var draft = TeachingDraft(section: "仁与礼", title: "仁礼关系")
        draft.blocks = [
            TeachingBlock(text: longBody, destination: .projection),
            TeachingBlock(text: "先讨论原文，再联系历史语境。", destination: .notes)
        ]
        let generated = try TeachingGenerator.generate([draft], template: .classroom)
        let bodyIndex = TeachingTemplate.classroom.slots[1]
        XCTAssertGreaterThan(generated.slides.count, 1)
        XCTAssertEqual(generated.slides.map { $0.objects[bodyIndex].text }.joined(), longBody)
        XCTAssertTrue(generated.slides.allSatisfy { !SlideText.isClipped($0.objects[bodyIndex]) })
        XCTAssertEqual(generated.slides[0].speakerNotes, draft.notes)
        XCTAssertTrue(generated.slides.dropFirst().allSatisfy { $0.speakerNotes.isEmpty })
    }

    @MainActor
    func testCustomTemplatePersistsWithArtworkAndWithoutPreviousLectureNotes() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let target = folder.appendingPathComponent("templates.json")
        let image = UUID()
        let otherImage = UUID()
        var slide = Slide.titleSlide("历史图示", subtitle: "解释")
        slide.objects.append(SlideObject(kind: .image, imageID: image))
        slide.speakerNotes = "已有课程讲稿"
        let store = TeachingTemplateStore(file: target)
        try store.save(TeachingTemplate(name: "史料模板", slide: slide, images: [image: Data([1]), otherImage: Data([2])]))
        let reopened = TeachingTemplateStore(file: target)
        let item = try XCTUnwrap(reopened.items.first)
        XCTAssertEqual(item.name, "史料模板")
        XCTAssertEqual(item.images, [image: Data([1])])
        XCTAssertTrue(item.slide.speakerNotes.isEmpty)
        XCTAssertTrue(item.canGenerate)
        try reopened.remove([item.id])
        XCTAssertTrue(TeachingTemplateStore(file: target).items.isEmpty)
    }

    func testTeacherNotesContinueAndStudentPDFKeepsNotesPrivate() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        var deck = Deck(slides: (1...5).map { Slide.titleSlide("Slide \($0)", subtitle: "Public material") })
        let marker = "PRIVATE_NOTE_ONLY"
        deck.slides[0].speakerNotes = String(repeating: "Period context and historical interpretation.\n", count: 115) + marker

        let notesURL = root.appendingPathComponent("notes.pdf")
        try TeachingPDF.write(deck, format: .teacher, to: notesURL)
        let teacher = try XCTUnwrap(PDFDocument(url: notesURL))
        XCTAssertGreaterThan(teacher.pageCount, 5)
        XCTAssertTrue((0..<teacher.pageCount).contains { teacher.page(at: $0)?.string?.contains(marker) == true })

        for (format, count) in [(TeachingPDF.Format.studentTwo, 3), (.studentThree, 2)] {
            let handoutURL = root.appendingPathComponent(format.label + ".pdf")
            try TeachingPDF.write(deck, format: format, to: handoutURL)
            let handout = try XCTUnwrap(PDFDocument(url: handoutURL))
            XCTAssertEqual(handout.pageCount, count)
            let contents = (0..<handout.pageCount).compactMap { handout.page(at: $0)?.string }.joined()
            XCTAssertTrue(contents.contains("Slide 1"))
            XCTAssertTrue(contents.contains("Slide 5"))
            XCTAssertFalse(contents.contains(marker))
            XCTAssertEqual(handout.page(at: 0)?.bounds(for: .mediaBox).width ?? 0, 595.28, accuracy: 0.1)
        }
    }
}
