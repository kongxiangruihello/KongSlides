import XCTest
@testable import KongSlides

final class EditingOperationsTests: XCTestCase {
    func testSlidePageNumberAcceptsFullwidthDigitsAndRejectsOutOfRangeInput() {
        XCTAssertEqual(SlidePageNumber.parse(" ８８ ", pageCount: 100), 88)
        XCTAssertEqual(SlidePageNumber.parse("100", pageCount: 100), 100)
        XCTAssertNil(SlidePageNumber.parse("0", pageCount: 100))
        XCTAssertNil(SlidePageNumber.parse("101", pageCount: 100))
        XCTAssertNil(SlidePageNumber.parse("8.5", pageCount: 100))
        XCTAssertNil(SlidePageNumber.parse("8 8", pageCount: 100))
        XCTAssertNil(SlidePageNumber.parse("99999999999999999999999", pageCount: 100))
    }

    func testResizeAnchorsOppositeCornerAndKeepsPictureAspect() {
        let frame = CGRect(x: 40, y: 50, width: 160, height: 80)
        let expanded = ResizeCorner.topLeft.resized(frame, translation: CGSize(width: -40, height: -10),
                                                    proportional: true)
        XCTAssertEqual(expanded, CGRect(x: 0, y: 30, width: 200, height: 100))
        let text = ResizeCorner.bottomRight.resized(frame, translation: CGSize(width: 0, height: 30),
                                                    proportional: false)
        XCTAssertEqual(text, CGRect(x: 40, y: 50, width: 160, height: 110))
    }

    func testPictureFillUsesCenteredCropAndMapsToTheFrame() {
        let area = PictureCrop.filling(image: CGSize(width: 400, height: 100),
                                      frame: CGSize(width: 200, height: 100))
        XCTAssertEqual(area, PictureCrop(left: 0.25, right: 0.25))
        XCTAssertEqual(area.imageRect(inside: CGRect(x: 100, y: 50, width: 200, height: 100)),
                       CGRect(x: 0, y: 50, width: 400, height: 100))
        XCTAssertFalse(PictureCrop(left: 0.6, right: 0.5).isValid)
    }

    func testBatchMovementAndClipboardKeepNotesAndPictureContent() throws {
        let asset = UUID()
        let picture = SlideObject(kind: .image, imageID: asset)
        let pages = ["甲", "乙", "丙", "丁", "戊"].map { Slide(speakerNotes: $0, objects: [picture]) }
        var deck = Deck(slides: pages, images: [asset: Data([1, 2, 3])])
        deck.moveSelectedSlides([pages[1].id, pages[2].id, pages[4].id], by: -1)
        XCTAssertEqual(deck.slides.map(\.speakerNotes), ["乙", "丙", "甲", "戊", "丁"])
        let payload = try SlideClipboard(slides: Array(deck.slides.prefix(2)), images: deck.images).validated()
        var other = Deck(images: [asset: Data([4])])
        let copies = payload.copies(into: &other)
        XCTAssertEqual(copies.map(\.speakerNotes), ["乙", "丙"])
        XCTAssertNotEqual(copies.first?.id, pages[1].id)
        let copiedAsset = try XCTUnwrap(copies.first?.objects.first?.imageID)
        XCTAssertNotEqual(copiedAsset, asset)
        XCTAssertEqual(other.images[copiedAsset], Data([1, 2, 3]))
    }

    func testDisplayAssignmentsSurviveUnplugReplugAndSwap() {
        XCTAssertEqual(PresentationDisplays.resolve([10, 20], preferProjection: 20, preferConsole: 10),
                       PresentationDisplays(projection: 20, console: 10))
        XCTAssertEqual(PresentationDisplays.resolve([10], preferProjection: 20, preferConsole: 10),
                       PresentationDisplays(projection: 10, console: nil))
        XCTAssertEqual(PresentationDisplays.resolve([20, 10], preferProjection: 20, preferConsole: 10),
                       PresentationDisplays(projection: 20, console: 10))
        XCTAssertEqual(PresentationDisplays.resolve([20, 10], preferProjection: 10, preferConsole: 20),
                       PresentationDisplays(projection: 10, console: 20))
    }
}
