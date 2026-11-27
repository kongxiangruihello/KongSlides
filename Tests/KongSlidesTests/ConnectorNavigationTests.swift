import Foundation
import XCTest
@testable import KongSlides

final class ConnectorNavigationTests: XCTestCase {
    func testDirectedHorizontalConnectorPreservesEndpointsAndFormattingThroughPPTX() throws {
        let start = CGPoint(x: 405, y: 90)
        let end = CGPoint(x: 115, y: 90)
        let style = SlideConnector(weight: 3, startArrow: .arrow, endArrow: .triangle, dash: .dashDot)
        let object = try XCTUnwrap(SlideConnector.object(from: start, to: end, style: style, color: "123ABC"))
        let deck = Deck(slides: [Slide(objects: [object])])
        XCTAssertEqual(try JSONDecoder().decode(Deck.self, from: JSONEncoder().encode(deck)).validated(), deck)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("pptx")
        defer { try? FileManager.default.removeItem(at: file) }
        try PowerPoint.write(deck, to: file)
        let imported = try PowerPoint.read(file, prepareImage: { _ in nil }).deck
        let restored = try XCTUnwrap(imported.slides.first?.objects.first)
        let line = try XCTUnwrap(restored.connector)
        let endpoints = line.endpoints(in: restored.frame)
        XCTAssertEqual(restored.kind, .connector)
        XCTAssertEqual(endpoints.start, start)
        XCTAssertEqual(endpoints.end, end)
        XCTAssertEqual(restored.color, "123ABC")
        XCTAssertEqual(line.startArrow, .arrow)
        XCTAssertEqual(line.endArrow, .triangle)
        XCTAssertEqual(line.weight, 3)
        XCTAssertEqual(line.dash, .dashDot)
    }

    func testEditorNavigationIncludesBackupPagesAndRespectsSearch() {
        let first = Slide()
        let backup = Slide(hiddenInShow: true)
        let last = Slide()
        let deck = Deck(slides: [first, backup, last])
        XCTAssertEqual(deck.editorPage(after: 0, direction: 1), backup.id)
        XCTAssertEqual(deck.editorPage(after: 2, direction: -1), backup.id)
        XCTAssertEqual(deck.editorPage(after: 0, direction: 1, matching: [first.id, last.id]), last.id)
        XCTAssertEqual(deck.editorPage(after: 1, direction: -1, matching: [first.id, last.id]), first.id)
        XCTAssertNil(deck.editorPage(after: 0, direction: -1))
        XCTAssertNil(deck.editorPage(after: 2, direction: 1))
        XCTAssertNil(deck.editorPage(after: 1, direction: 1, matching: []))
    }
}
