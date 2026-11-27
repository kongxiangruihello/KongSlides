import Foundation
import XCTest
@testable import KongSlides

final class FontPictureTests: XCTestCase {
    func testMissingFontReportedAndReplacementPreservesRunAttributes() throws {
        let old = "KongSlides Missing Test Family 713A"
        let layout = SlideTextLayout(fontName: old)
        let run = SlideTextRun(start: 0, length: 2, size: 18, bold: true, color: "123ABC",
                               fontName: old, baseline: 0.3)
        let object = SlideObject(text: "經學史", textLayout: layout, textRuns: [run])
        var deck = Deck(slides: [Slide(objects: [object])])
        XCTAssertEqual(SlideFonts.requested(in: deck), [old])
        let finding = SlideReviewRow.preflight(deck).first { $0.title == "字体缺失" }
        XCTAssertEqual(finding?.objectID, object.id)
        XCTAssertEqual(finding?.detail, old)
        SlideFonts.replace(old, with: "Helvetica", in: &deck)
        let edited = try XCTUnwrap(deck.slides.first?.objects.first)
        var expected = run
        expected.fontName = "Helvetica"
        XCTAssertEqual(edited.textRuns, [expected])
        XCTAssertEqual(edited.text, object.text)
        XCTAssertEqual(edited.textLayout?.fontName, "Helvetica")
        XCTAssertFalse(SlideReviewRow.preflight(deck).contains { $0.title == "字体缺失" })
    }

    func testPictureAppearanceRoundTripsWithCropAndChangesPreflightBounds() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("pptx")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let imageID = UUID()
        let picture = SlideObject(kind: .image, x: 100, y: 0, width: 220, height: 50, imageID: imageID,
                                  pictureCrop: PictureCrop(left: 0.1),
                                  pictureAppearance: PictureAppearance(angle: -90, opacity: 0.45,
                                                                        flipHorizontal: true, flipVertical: true))
        let image = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aTioAAAAASUVORK5CYII="))
        let deck = Deck(slides: [Slide(objects: [picture])], images: [imageID: image])
        XCTAssertTrue(SlideReviewRow.preflight(deck).contains { $0.title == "图片超出画布" })
        try PowerPoint.write(deck, to: temporary)
        let imported = try PowerPoint.read(temporary, prepareImage: { $0 }).deck
        let restored = try XCTUnwrap(imported.slides.first?.objects.first)
        XCTAssertEqual(restored.pictureAppearance, picture.pictureAppearance)
        XCTAssertEqual(restored.pictureCrop, picture.pictureCrop)
        XCTAssertFalse(imported.slides[0].importReport?.diagnostics.contains { $0.detail.contains("旋转或翻转未保留") } ?? true)
    }
}
