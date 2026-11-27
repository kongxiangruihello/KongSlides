import Foundation
import XCTest
@testable import KongSlides

final class PowerPointTableTests: XCTestCase {
    func testRestructuringTablePreservesMergeCoverageAndText() {
        var table = SlideTable(columns: [1, 1], rows: [1], cells: [
            .init(row: 0, column: 0, text: "原文"), .init(row: 0, column: 1, text: "解读")
        ])
        table.mergeCell("0:0", along: .column)
        XCTAssertTrue(table.isValid)
        XCTAssertEqual(table.cells.first?.text, "原文\n解读")
        table.appendTrack(.row)
        table.appendTrack(.column)
        table.removeTrack(.column, at: 0)
        XCTAssertTrue(table.isValid)
        XCTAssertEqual(table.cells.first?.text, "原文\n解读")
        table.mergeCell("0:0", along: .row)
        table.splitCell("0:0")
        XCTAssertTrue(table.isValid)
        XCTAssertEqual(table.cells.count, 4)
    }

    func testTableRoundTripPreservesMergeCellFormattingAndGeometry() throws {
        let cell = SlideTable.Cell(row: 0, column: 0, rowSpan: 2, columnSpan: 2,
                                   text: "經學史", fontSize: 22, bold: true, fill: "EDF2FC",
                                   layout: SlideTextLayout(fontName: "Helvetica"),
                                   runs: [SlideTextRun(start: 0, length: 1, size: 28, bold: true, color: "123ABC")])
        let table = SlideTable(columns: [2, 1, 1], rows: [1, 2],
                               cells: [cell, .init(row: 0, column: 2, text: "上"), .init(row: 1, column: 2, text: "下")])
        let object = SlideObject(kind: .table, x: 60, y: 90, width: 400, height: 150, table: table)
        let deck = Deck(slides: [Slide(objects: [object])])
        let native = try JSONDecoder().decode(Deck.self, from: JSONEncoder().encode(deck)).validated()
        XCTAssertEqual(native, deck)

        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("pptx")
        defer { try? FileManager.default.removeItem(at: file) }
        try PowerPoint.write(deck, to: file)
        let converted = try PowerPoint.read(file, prepareImage: { _ in nil }).deck
        let imported = try XCTUnwrap(converted.slides.first?.objects.first)
        let restored = try XCTUnwrap(imported.table)
        XCTAssertEqual(imported.frame, object.frame)
        XCTAssertEqual(restored.occupancy, [0, 0, 1, 0, 0, 2])
        XCTAssertEqual(SlideTable.edges(restored.columns, across: 400), [0, 200, 300, 400])
        XCTAssertEqual(SlideTable.edges(restored.rows, across: 150), [0, 50, 150])
        XCTAssertEqual(restored.cells.map(\.text), ["經學史", "上", "下"])
        XCTAssertEqual(restored.cells[0].fill, "EDF2FC")
        XCTAssertEqual(restored.cells[0].runs?.first?.size, 28)
        XCTAssertEqual(restored.cells[0].runs?.first?.color, "123ABC")
        XCTAssertTrue(converted.slides[0].importReport?.diagnostics.isEmpty == true)
    }

    func testOverlappingAnchorsFailNativeValidation() {
        let table = SlideTable(columns: [1, 1], rows: [1],
                               cells: [.init(row: 0, column: 0, columnSpan: 2), .init(row: 0, column: 1)])
        XCTAssertThrowsError(try Deck(slides: [Slide(objects: [SlideObject(kind: .table, table: table)])]).validated())
    }
}
