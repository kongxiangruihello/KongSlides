import AppKit
import XCTest
@testable import KongSlides

final class EditorWindowTests: XCTestCase {
    func testSidebarClicksAlwaysMakeTheClickedPageCurrent() {
        let pages = (0..<6).map { _ in UUID() }
        var state = SidebarPageSelection(current: pages[0], selected: [pages[0]], anchor: pages[0])
        state.click(pages[4], in: pages, mode: .single)
        XCTAssertEqual(state.current, pages[4])
        XCTAssertEqual(state.selected, [pages[4]])
        state.click(pages[1], in: pages, mode: .range)
        XCTAssertEqual(state.current, pages[1])
        XCTAssertEqual(state.selected, Set(pages[1...4]))
        state.click(pages[3], in: pages, mode: .single)
        XCTAssertEqual(state.current, pages[3])
        XCTAssertEqual(state.selected, [pages[3]])
        state.click(pages[5], in: pages, mode: .toggle)
        XCTAssertEqual(state.current, pages[5])
        XCTAssertEqual(state.selected, [pages[3], pages[5]])
        state.click(pages[5], in: pages, mode: .toggle)
        XCTAssertEqual(state.current, pages[3])
    }

    @MainActor
    func testOpeningNativeAndPowerPointReusesTheEditorWindowAndKeepsNativeSavePath() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let native = directory.appendingPathComponent("旧课件.kongslides")
        let nativeDeck = Deck(slides: [Slide.titleSlide("旧课件", subtitle: "")])
        try SlidesDocument(deck: nativeDeck).writeNative(to: native)
        let pptx = directory.appendingPathComponent("待导入.pptx")
        try PowerPoint.write(Deck(slides: [Slide.titleSlide("新课件", subtitle: "")]), to: pptx)

        let editor = EditorWindow()
        let window = try XCTUnwrap(editor.window)
        defer { window.close() }
        let session = editor.session
        editor.open(native)
        try await finishOpening(session)
        XCTAssertTrue(editor.window === window)
        XCTAssertEqual(session.fileURL, native)
        XCTAssertEqual(session.document.deck, nativeDeck)
        XCTAssertTrue(window.title.contains("旧课件"))
        var changed = session.document
        changed.deck.slides[0].speakerNotes = "保存到原文件"
        session.edit(changed)
        XCTAssertTrue(window.isDocumentEdited)
        // An unreadable file leaves edits and the save target intact.
        session.open(directory.appendingPathComponent("损坏.kongslides"))
        try await finishOpening(session)
        XCTAssertNotNil(session.error)
        XCTAssertEqual(session.document.deck, changed.deck)
        XCTAssertTrue(session.save())
        XCTAssertEqual(try SlidesDocument.readNative(native).deck, changed.deck)
        editor.open(pptx)
        try await finishOpening(session)
        XCTAssertTrue(editor.window === window)
        XCTAssertEqual(session.document.deck.slides.first?.title, "新课件")
        XCTAssertNil(session.fileURL)
        XCTAssertEqual(session.currentDocumentURL, pptx)
        XCTAssertEqual(session.screen, .editor)
        XCTAssertTrue(window.title.contains("待导入"))
        XCTAssertFalse(window.isDocumentEdited)
    }

    @MainActor
    func testReopenRestoresSavedSlideByIDAndIgnoresStaleEditorEvents() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "kongslides-tests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let positions = RecentSlidePositions(defaults: defaults)
        let first = Slide.titleSlide("第一课", subtitle: "")
        let second = Slide.titleSlide("第二课", subtitle: "")
        let third = Slide.titleSlide("第三课", subtitle: "")
        let file = directory.appendingPathComponent("课件.kongslides")
        let other = directory.appendingPathComponent("另一份课件.kongslides")
        try SlidesDocument(deck: Deck(slides: [first, second])).writeNative(to: file)
        try SlidesDocument(deck: Deck(slides: [third, first])).writeNative(to: other)

        let session = EditorFileSession(positions: positions)
        session.open(file)
        try await finishOpening(session)
        let previous = session.identity
        session.rememberPage(second.id, for: previous)
        XCTAssertFalse(session.isEdited)
        session.open(other)
        try await finishOpening(session)
        session.rememberPage(first.id, for: previous)
        XCTAssertEqual(session.activePageID, third.id)
        XCTAssertNil(positions.page(for: other))
        XCTAssertEqual(positions.page(for: file), second.id)

        try SlidesDocument(deck: Deck(slides: [third, second, first])).writeNative(to: file)
        let reopened = EditorFileSession(positions: RecentSlidePositions(defaults: defaults))
        reopened.open(file)
        try await finishOpening(reopened)
        XCTAssertEqual(reopened.activePageID, second.id)

        try SlidesDocument(deck: Deck(slides: [first, third])).writeNative(to: file)
        session.open(file)
        try await finishOpening(session)
        XCTAssertEqual(session.activePageID, first.id)
    }

    @MainActor
    func testLaunchHomeFavoritesAndResumeWithoutChangingDocumentIdentity() throws {
        _ = NSApplication.shared
        let suite = "kongslides-home-tests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let session = EditorFileSession(favorites: FavoriteDocuments(defaults: defaults))
        XCTAssertEqual(session.screen, .home)
        XCTAssertTrue(session.beginLaunch())
        XCTAssertEqual(session.screen, .splash)
        session.finishLaunch()
        XCTAssertEqual(session.screen, .home)
        XCTAssertFalse(session.hasDocument)

        let file = FileManager.default.temporaryDirectory.appendingPathComponent("课堂导入.pptx")
        session.toggleFavorite(file)
        XCTAssertTrue(session.isFavorite(file))
        let reloaded = EditorFileSession(favorites: FavoriteDocuments(defaults: defaults))
        XCTAssertTrue(reloaded.isFavorite(file))
        reloaded.toggleFavorite(file)
        XCTAssertTrue(FavoriteDocuments(defaults: defaults).urls.isEmpty)

        session.newDeck()
        let document = session.identity
        let page = session.activePageID
        XCTAssertEqual(session.screen, .editor)
        session.showHome()
        XCTAssertTrue(session.hasDocument)
        XCTAssertEqual(session.screen, .home)
        session.continueEditing()
        XCTAssertEqual(session.screen, .editor)
        XCTAssertEqual(session.identity, document)
        XCTAssertEqual(session.activePageID, page)
        session.resetAfterClose()
        XCTAssertEqual(session.screen, .home)
        XCTAssertFalse(session.hasDocument)
    }

    @MainActor
    private func finishOpening(_ session: EditorFileSession) async throws {
        for _ in 0..<400 where session.opening {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertFalse(session.opening)
    }
}
