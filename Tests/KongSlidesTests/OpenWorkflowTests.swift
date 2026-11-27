import Foundation
import XCTest
@testable import KongSlides

final class OpenWorkflowTests: XCTestCase {
    func testImageCacheReusesVariantsAndReplacesChangedAsset() throws {
        let data = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAIAAAD91JpzAAAAFklEQVR4nGOUt0piYGBgYmBgYGBgAAAIqwC/4jgdqwAAAABJRU5ErkJggg=="))
        let cache = SlideImageCache()
        let id = UUID()
        let preview = try XCTUnwrap(cache.picture(data, id: id, thumbnail: true))
        let repeated = try XCTUnwrap(cache.picture(data, id: id, thumbnail: true))
        let full = try XCTUnwrap(cache.picture(data, id: id, thumbnail: false))
        XCTAssertTrue(preview === repeated)
        XCTAssertFalse(preview === full)
        XCTAssertNil(cache.picture(Data(), id: id, thumbnail: true))
    }

    func testSummaryCountsDistinctFailedPagesAndAdvancesPastRepairs() {
        func row(_ id: UUID, page: Int, repair: SlideImportReport.Repair? = nil) -> SlideReviewRow {
            SlideReviewRow(slideID: id, objectID: nil, page: page, title: "读取失败", detail: "文件缺页",
                           impact: .pageUnavailable, repair: repair)
        }
        let first = UUID(), second = UUID(), last = UUID()
        let rows = [row(first, page: 2), row(first, page: 2),
                    row(second, page: 3, repair: .init(pdfName: "参考.pdf", pdfPage: 3)), row(last, page: 5)]
        let summary = ImportReviewSummary(total: 5, rows: rows)
        XCTAssertEqual(summary.readable, 2)
        XCTAssertEqual(summary.repaired, 1)
        XCTAssertEqual(summary.pending.map(\.page), [2, 5])
        XCTAssertEqual(summary.next(after: 2)?.page, 5)
        XCTAssertEqual(summary.next(after: 5)?.page, 2)
    }

    @MainActor
    func testOpeningNinetyFourPageNativeDeckRecordsSeparatePhases() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".kongslides")
        defer { try? FileManager.default.removeItem(at: file) }
        let deck = Deck(slides: (1...94).map { Slide.titleSlide("第 \($0) 页", subtitle: "课堂课件") })
        try SlidesDocument(deck: deck).writeNative(to: file)
        let session = EditorFileSession()
        session.open(file)
        for _ in 0..<200 where session.opening { try await Task.sleep(for: .milliseconds(20)) }
        let timing = try XCTUnwrap(session.openTiming)
        XCTAssertEqual(timing.pageCount, 94)
        XCTAssertEqual(timing.imagePreparation, 0)
        XCTAssertGreaterThan(timing.readAndConvert, 0)
        session.recordFirstDraw(for: UUID(), at: OpenTiming.now, imageTime: 0)
        XCTAssertNil(session.openTiming?.firstDraw)
        session.recordFirstDraw(for: session.identity, at: OpenTiming.now, imageTime: 0.002)
        XCTAssertEqual(session.openTiming?.displayImagePreparation, 0.002)
        for _ in 0..<20 where session.openTiming?.readyAfterDraw == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotNil(session.openTiming?.readyAfterDraw)
    }

    func testWriteWindowsClassroomFixture() throws {
        guard let path = ProcessInfo.processInfo.environment["KONGSLIDES_WINDOWS_FIXTURE"] else { return }
        let group = UUID()
        let target = SlideObject(kind: .rectangle, x: 60, y: 175, width: 150, height: 65, groupID: group)
        let sample = SlideObject(x: 60, y: 65, width: 500, height: 75, text: "经学史课堂样例",
                                 textLayout: SlideTextLayout(fontName: "Microsoft YaHei"))
        let link = SlideConnector(startAttachment: .init(objectID: target.id, edge: .right), endArrow: .triangle)
        var arrow = try XCTUnwrap(SlideConnector.object(from: CGPoint(x: 210, y: 207.5),
                                                        to: CGPoint(x: 415, y: 207.5), style: link))
        arrow.groupID = group
        let table = SlideTable(columns: [2, 1], rows: [1, 1], cells: [
            .init(row: 0, column: 0, columnSpan: 2, text: "史料"),
            .init(row: 1, column: 0, text: "原文"), .init(row: 1, column: 1, text: "解读")
        ])
        let grid = SlideObject(kind: .table, x: 55, y: 275, width: 460, height: 165, table: table)
        let deck = Deck(slides: [Slide(speakerNotes: "教师讲稿验收", objects: [sample, target, arrow, grid])])
        try PowerPoint.write(deck, to: URL(fileURLWithPath: path))
    }
}
