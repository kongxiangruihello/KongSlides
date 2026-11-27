import Foundation
import XCTest
@testable import KongSlides

final class ConnectorNavigationTests: XCTestCase {
    func testGroupedRectangleAndAttachedConnectorSurvivePowerPointRoundTrip() throws {
        let group = UUID()
        let target = SlideObject(kind: .rectangle, x: 60, y: 100, width: 120, height: 80, groupID: group)
        let style = SlideConnector(startAttachment: .init(objectID: target.id, edge: .right), endArrow: .triangle)
        var arrow = try XCTUnwrap(SlideConnector.object(from: CGPoint(x: 180, y: 140), to: CGPoint(x: 340, y: 140), style: style))
        arrow.groupID = group
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pptx")
        defer { try? FileManager.default.removeItem(at: url) }
        try PowerPoint.write(Deck(slides: [Slide(objects: [target, arrow])]), to: url)
        var page = try XCTUnwrap(PowerPoint.read(url, prepareImage: { $0 }).deck.slides.first)
        let importedGroup = try XCTUnwrap(page.objects.first?.groupID)
        XCTAssertEqual(page.objects.last?.groupID, importedGroup)
        XCTAssertEqual(page.objects.last?.connector?.startAttachment?.objectID, page.objects.first?.id)
        page.objects[0].x += 35
        page.resolveConnectorAttachments()
        let connector = try XCTUnwrap(page.objects.last)
        let endpoints = try XCTUnwrap(connector.connector).endpoints(in: connector.frame)
        XCTAssertEqual(endpoints.start, CGPoint(x: 215, y: 140))
        XCTAssertEqual(endpoints.end, CGPoint(x: 340, y: 140))
    }

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
