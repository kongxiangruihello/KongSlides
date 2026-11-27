import Foundation
import CoreGraphics
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
        let marker = "PRIVATELECTUREMARKER"
        deck.slides[0].speakerNotes = String(repeating: "Period context and historical interpretation.\n", count: 115) + marker

        let notesURL = root.appendingPathComponent("notes.pdf")
        try TeachingPDF.write(deck, format: .teacher, to: notesURL)
        let teacher = try XCTUnwrap(PDFDocument(url: notesURL))
        XCTAssertGreaterThan(teacher.pageCount, 5)
        let teacherPages = (0..<teacher.pageCount).compactMap { teacher.page(at: $0)?.string }
        let teacherText = teacherPages.joined(separator: "\n")
        XCTAssertEqual(teacherText.components(separatedBy: "Period context and historical interpretation.").count - 1, 115)
        XCTAssertTrue(teacherText.contains(marker), "Last frames of the teacher PDF: \(teacherPages.prefix(6).map { $0.suffix(110) })")

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

    func testChapterPackageCreatesThreePDFsWithoutOverwritingAnEarlierExport() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let deck = Deck(slides: [Slide.titleSlide("原文", subtitle: "内容")])
        let first = try TeachingPDF.chapterPackage(deck, title: "讲稿/第一章", in: folder)
        let second = try TeachingPDF.chapterPackage(deck, title: "讲稿/第一章", in: folder)
        XCTAssertNotEqual(first, second)
        for package in [first, second] {
            let entries = try FileManager.default.contentsOfDirectory(at: package, includingPropertiesForKeys: nil)
            XCTAssertEqual(entries.count, 3)
            XCTAssertTrue(entries.allSatisfy { PDFDocument(url: $0)?.pageCount == 1 })
        }
    }


    func testPreviewLayoutUsesGeneratedPageRangesAndPlacesNotesOnContinuation() throws {
        let first = TeachingDraft(section: "原典", title: "章首")
        let second = TeachingDraft(section: "原典", title: "原文", blocks: [
            TeachingBlock(text: String(repeating: "仁者爱人，礼者敬人。", count: 130), destination: .projection),
            TeachingBlock(text: "第一页的说明", destination: .notes),
            TeachingBlock(text: "续页的说明", destination: .notes, notesPage: 2)
        ])
        let layout = try TeachingGenerator.layout([first, second], template: .classroom)
        let range = try XCTUnwrap(layout.ranges[second.id])
        XCTAssertEqual(layout.ranges[first.id], 0..<1)
        XCTAssertGreaterThan(range.count, 1)
        XCTAssertEqual(range.upperBound, layout.clipboard.slides.count)
        XCTAssertEqual(layout.clipboard.slides[range.lowerBound].speakerNotes, "第一页的说明")
        XCTAssertEqual(layout.clipboard.slides[range.lowerBound + 1].speakerNotes, "续页的说明")
    }

    func testReferencePDFPairsBySourcePageAndPreservesNotesWhenReplacing() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("pdf")
        defer { try? FileManager.default.removeItem(at: file) }
        let exported = Deck(slides: [Slide(), Slide.titleSlide("Reference", subtitle: "Original")])
        try SlideDrawing.pdf(exported, to: file)
        let pdf = try XCTUnwrap(CGPDFDocument(file as CFURL))
        var slide = Slide(section: "经学史", speakerNotes: "逐字讲稿", hiddenInShow: true)
        slide.importReport = SlideImportReport(sourceName: "原稿.pptx", sourcePage: 2, diagnostics: [
            ImportDiagnostic(kind: .unsupported, detail: "无法转换源第 2 页", objectID: nil)
        ])
        let page = try XCTUnwrap(ReferencePDF.pageIndex(for: slide, position: 0, pageCount: pdf.numberOfPages))
        XCTAssertEqual(page, 1)
        let image = try ReferencePDF.image(in: pdf, page: page)
        XCTAssertEqual(image.width, 2400)
        XCTAssertEqual(image.height, 1350)

        let oldID = slide.id
        let asset = UUID()
        ReferencePDF.replace(&slide, with: asset, size: CGSize(width: image.width, height: image.height),
                             repair: .init(pdfName: "参考.pdf", pdfPage: page + 1))
        XCTAssertEqual(slide.id, oldID)
        XCTAssertEqual(slide.speakerNotes, "逐字讲稿")
        XCTAssertEqual(slide.section, "经学史")
        XCTAssertTrue(slide.isBackup)
        XCTAssertEqual(slide.importReport?.sourcePage, 2)
        XCTAssertEqual(slide.importReport?.diagnostics.first?.impact, .pageUnavailable)
        let row = try XCTUnwrap(SlideReviewRow.imported(Deck(slides: [slide])).first)
        XCTAssertEqual(row.repair?.pdfPage, 2)
        XCTAssertTrue(SlideReviewRow.exportTSV(Deck(slides: [slide])).contains("参考.pdf 第 2 页"))
        XCTAssertEqual(slide.objects.first?.imageID, asset)
        XCTAssertEqual(slide.objects.first?.frame, CGRect(origin: .zero, size: Deck.size))
    }

}
