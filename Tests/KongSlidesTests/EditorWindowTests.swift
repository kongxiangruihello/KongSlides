import AppKit
import XCTest
@testable import KongSlides

final class EditorWindowTests: XCTestCase {
    @MainActor
    func testSaveAsPowerPointWritesEditableCopyAndPreservesNativeSession() async throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let suite = "kongslides-pptx-copy-tests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let original = folder.appendingPathComponent("原课件.kongslides")
        let copy = folder.appendingPathComponent("可编辑副本.pptx")
        let deck = Deck(slides: [.titleSlide("原课件", subtitle: ""), .titleSlide("备课", subtitle: "")])
        try SlidesDocument(deck: deck).writeNative(to: original)
        let session = EditorFileSession(positions: RecentSlidePositions(defaults: defaults),
                                        favorites: FavoriteDocuments(defaults: defaults))
        session.open(original)
        try await finishOpening(session)
        session.rememberPage(deck.slides[1].id, for: session.identity)
        var edited = session.document
        edited.deck.slides[1].objects[0].replaceText(with: "可编辑中文\n第二项")
        edited.deck.slides[1].objects[0].toggleList(in: [], numbered: true)
        edited.deck.slides[1].speakerNotes = "导出的讲稿"
        session.edit(edited)
        try await session.writeRequestedSave(to: copy, format: .powerPoint)
        XCTAssertFalse(session.saving)
        XCTAssertTrue(session.isEdited)
        XCTAssertEqual(session.fileURL, original)
        XCTAssertEqual(session.activePageID, deck.slides[1].id)
        XCTAssertEqual(try SlidesDocument.readNative(original).deck, deck)
        let exported = try PowerPoint.read(copy, prepareImage: { $0 }).deck.slides[1]
        XCTAssertEqual(exported.objects[0].text, "可编辑中文\n第二项")
        XCTAssertEqual(exported.objects[0].paragraphStyles.map { $0.bullet?.marker }, ["1.", "2."])
        XCTAssertEqual(exported.speakerNotes, "导出的讲稿")
    }

    @MainActor
    func testSaveAsWritesAnIndependentLargeCopyAndKeepsTheCurrentPage() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "kongslides-save-tests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let original = directory.appendingPathComponent("原课件.kongslides")
        let copy = directory.appendingPathComponent("另存副本.kongslides")
        let deck = Deck(slides: (1...94).map { Slide.titleSlide("第\($0)页", subtitle: "讲课") })
        try SlidesDocument(deck: deck).writeNative(to: original)
        let session = EditorFileSession(positions: RecentSlidePositions(defaults: defaults),
                                        favorites: FavoriteDocuments(defaults: defaults))
        session.open(original)
        try await finishOpening(session)
        session.rememberPage(deck.slides[79].id, for: session.identity)
        var edited = session.document
        edited.deck.slides[79].speakerNotes = "只写入副本"
        session.edit(edited)
        try await session.writeRequestedSave(to: copy)
        XCTAssertFalse(session.saving)
        XCTAssertFalse(session.isEdited)
        XCTAssertEqual(session.fileURL, copy)
        XCTAssertEqual(session.activePageID, deck.slides[79].id)
        XCTAssertEqual(try SlidesDocument.readNative(original).deck, deck)
        XCTAssertEqual(try SlidesDocument.readNative(copy).deck, edited.deck)

        let invalid = directory.appendingPathComponent("缺少文件夹/错误目标.kongslides")
        do {
            try await session.writeRequestedSave(to: invalid)
            XCTFail("A save into a missing directory must fail")
        } catch {
            XCTAssertEqual(session.fileURL, copy)
            XCTAssertFalse(session.saving)
        }
    }

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

    func testHomeBackupMergesGroupsAndRelocatesFavoritesWithoutLosingOrder() throws {
        let group = HomeLibrary.Group(name: "论语导读")
        let old = "/旧目录/第一讲.pptx"
        let next = "/新目录/第一讲.pptx"
        let second = "/课件/第二讲.kongslides"
        var library = HomeLibrary(groups: [group], favorites: [.init(path: old, group: group.id)])
        library.noteOpened(URL(fileURLWithPath: old))
        library.lastEdited = old
        library.previews[old] = .init(title: "第二节", section: "礼", page: 3, pageID: nil, total: 10, backups: 1,
                                     pendingRepairs: 1, thumbnailPNG: Data([1]), coverPNG: Data([2]), preflightPages: 2)
        XCTAssertNil(library.portableBackup().previews[old]?.thumbnailPNG)
        XCTAssertNil(library.portableBackup().previews[old]?.coverPNG)
        library.relocate(old, to: URL(fileURLWithPath: next))
        XCTAssertEqual(library.lastEdited, next)
        XCTAssertEqual(library.favorites.first?.group, group.id)
        XCTAssertEqual(library.recent, [next])
        XCTAssertEqual(library.previews[next]?.page, 3)
        let incoming = HomeLibrary.Group(name: group.name)
        library.merge(HomeLibrary(groups: [incoming], favorites: [.init(path: second, group: incoming.id)]))
        XCTAssertEqual(library.groups.count, 1)
        XCTAssertEqual(library.favorites.last?.group, group.id)
        library.move(second, before: next)
        XCTAssertEqual(library.favorites.map(\.path), [second, next])
    }

    @MainActor
    func testResumeRecordRestoresSavedPageAndRecentRemovalDoesNotRemoveFavorite() async throws {
        _ = NSApplication.shared
        let suite = "kongslides-home-resume-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".kongslides")
        defer { try? FileManager.default.removeItem(at: file) }
        let first = Slide.titleSlide("第一讲", subtitle: "")
        let second = Slide.titleSlide("第二讲", subtitle: "")
        try SlidesDocument(deck: Deck(slides: [first, second])).writeNative(to: file)
        let favorites = FavoriteDocuments(defaults: defaults)
        let session = EditorFileSession(positions: .init(defaults: defaults), favorites: favorites)
        session.open(file)
        try await finishOpening(session)
        session.rememberPage(second.id, for: session.identity)
        session.toggleFavorite(file)
        session.removeRecent(file)
        XCTAssertTrue(session.isFavorite(file))
        XCTAssertFalse(session.recentURLs.contains { HomeLibrary.path($0) == HomeLibrary.path(file) })
        let reopened = EditorFileSession(positions: .init(defaults: defaults), favorites: favorites)
        XCTAssertEqual(reopened.homeLibrary.previews[HomeLibrary.path(file)]?.page, 2)
        reopened.open(file)
        try await finishOpening(reopened)
        XCTAssertEqual(reopened.activePageID, second.id)
        reopened.showHome()
        reopened.requestHomeAction(.preflight)
        XCTAssertEqual(reopened.screen, .editor)
        XCTAssertNotNil(reopened.homeAction)
    }

    @MainActor
    private func finishOpening(_ session: EditorFileSession) async throws {
        for _ in 0..<400 where session.opening {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertFalse(session.opening)
    }
}
