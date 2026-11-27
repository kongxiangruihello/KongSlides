import AppKit
import Observation
import UniformTypeIdentifiers

struct NativeDocumentStamp: Equatable, Sendable {
    let modified: Date
    let size: UInt64
    let inode: UInt64

    init?(at url: URL) {
        guard let info = try? FileManager.default.attributesOfItem(atPath: url.resolvingSymlinksInPath().path),
              let modified = info[.modificationDate] as? Date,
              let size = (info[.size] as? NSNumber)?.uint64Value,
              let inode = (info[.systemFileNumber] as? NSNumber)?.uint64Value else { return nil }
        self.modified = modified
        self.size = size
        self.inode = inode
    }
}

private struct OpenedDeck {
    let deck: Deck
    var stamp: NativeDocumentStamp? = nil
    var imagePreparation = 0.0
}

private enum NativeDocumentChanged: LocalizedError {
    case externalModification

    var errorDescription: String? { "文件已被其他应用或同步服务修改。请重新打开，或把当前课件另存为副本。" }
}

@MainActor @Observable
final class EditorFileSession {
    enum Screen: Equatable { case splash, home, editor }

    private(set) var screen: Screen = .home
    private(set) var hasDocument = false
    private(set) var sourceURL: URL?
    private(set) var favoriteURLs: [URL] = []
    private(set) var recentURLs: [URL] = []
    private(set) var document = SlidesDocument()
    private(set) var fileURL: URL?
    private(set) var identity = UUID()
    private(set) var activePageID: UUID?
    private(set) var opening = false
    private(set) var openTiming: OpenTiming?
    private(set) var progress = ImportProgress()
    var error: String?
    var pageJumpRequest = UUID()

    @ObservationIgnored let undoManager = UndoManager()
    @ObservationIgnored var statusChanged: (() -> Void)?
    @ObservationIgnored private var savedDeck: Deck?
    @ObservationIgnored private var reader: Task<OpenedDeck, Error>?
    @ObservationIgnored private var operation: UUID?
    @ObservationIgnored private var savedStamp: NativeDocumentStamp?

    @ObservationIgnored private let positions: RecentSlidePositions
    @ObservationIgnored private let favorites: FavoriteDocuments

    init(positions: RecentSlidePositions = .init(), favorites: FavoriteDocuments = .init()) {
        self.positions = positions
        self.favorites = favorites
        favoriteURLs = favorites.urls
        savedDeck = document.deck
        activePageID = document.deck.slides.first?.id
    }

    var currentDocumentURL: URL? { fileURL ?? sourceURL }

    func beginLaunch() -> Bool {
        guard !opening, !hasDocument, screen == .home else { return false }
        screen = .splash
        statusChanged?()
        return true
    }

    func finishLaunch() {
        if screen == .splash { showHome() }
    }

    func showHome() {
        refreshRecent()
        screen = .home
        statusChanged?()
    }

    func continueEditing() {
        guard hasDocument else { return }
        screen = .editor
        statusChanged?()
    }

    func refreshRecent() {
        var seen = Set<URL>()
        recentURLs = NSDocumentController.shared.recentDocumentURLs.filter {
            $0.isFileURL && ["ppt", "pptx", "kongslides"].contains($0.pathExtension.lowercased()) &&
                seen.insert(FavoriteDocuments.canonical($0)).inserted
        }
    }

    func clearRecent() {
        NSDocumentController.shared.clearRecentDocuments(nil)
        refreshRecent()
    }

    func isFavorite(_ url: URL) -> Bool {
        let target = FavoriteDocuments.canonical(url)
        return favoriteURLs.contains { FavoriteDocuments.canonical($0) == target }
    }

    func toggleFavorite(_ url: URL) {
        favorites.toggle(url)
        favoriteURLs = favorites.urls
    }

    func rememberPage(_ page: UUID, for editor: UUID) {
        guard editor == identity, document.deck.slides.contains(where: { $0.id == page }) else { return }
        activePageID = page
        if let fileURL { positions.remember(page, for: fileURL) }
    }

    var name: String {
        fileURL?.deletingPathExtension().lastPathComponent ?? document.deck.importedTitle ?? "未命名课件"
    }

    var isEdited: Bool { document.deck != savedDeck }

    func edit(_ value: SlidesDocument) {
        guard document.deck != value.deck else { return }
        let previous = document
        var value = value
        for index in value.deck.slides.indices where value.deck.slides[index].objects.contains(where: {
            $0.connector?.startAttachment != nil || $0.connector?.endAttachment != nil
        }) {
            if !previous.deck.slides.indices.contains(index) ||
                previous.deck.slides[index].objects != value.deck.slides[index].objects {
                value.deck.slides[index].resolveConnectorAttachments()
            }
        }
        undoManager.registerUndo(withTarget: self) { session in
            MainActor.assumeIsolated { session.edit(previous) }
        }
        document = value
        statusChanged?()
    }

    func chooseFile() {
        finishLaunch()
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.kongSlides, .slidePowerPoint] + [UTType(filenameExtension: "ppt")].compactMap { $0 }
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }

    func open(_ url: URL, discardEditsToReload: Bool = false) {
        guard url.isFileURL, ["kongslides", "pptx", "ppt"].contains(url.pathExtension.lowercased()) else { return }
        if !discardEditsToReload, let currentDocumentURL,
           FavoriteDocuments.canonical(currentDocumentURL) == FavoriteDocuments.canonical(url) {
            cancelOpening()
            continueEditing()
            return
        }
        finishLaunch()
        cancelOpening()
        let request = UUID()
        let requestedAt = OpenTiming.now
        operation = request
        opening = true
        error = nil
        let progress = ImportProgress()
        self.progress = progress
        let work = Task.detached(priority: .userInitiated) {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            if url.pathExtension.lowercased() == "kongslides" {
                let stamp = NativeDocumentStamp(at: url)
                let opened = try SlidesDocument.readNative(url)
                guard stamp == NativeDocumentStamp(at: url) else { throw NativeDocumentChanged.externalModification }
                return OpenedDeck(deck: opened.deck, stamp: stamp)
            }
            var imagePreparation = 0.0
            let imported = try PowerPoint.readForEditor(url, imageTime: { imagePreparation += $0 }) { completed, total in
                Task { @MainActor in
                    progress.completed = max(progress.completed, completed)
                    progress.total = total
                }
            }
            return OpenedDeck(deck: imported.deck, imagePreparation: imagePreparation)
        }
        reader = work
        Task {
            defer { if operation == request { cancelOpening() } }
            do {
                let opened = try await work.value
                let loadedAt = OpenTiming.now
                guard operation == request, !work.isCancelled else { return }
                let destination = url.pathExtension.lowercased() == "kongslides" ? url : nil
                guard (discardEditsToReload || confirmReplacement()), operation == request, !work.isCancelled else { return }
                install(opened.deck, at: destination, markEdited: false, stamp: opened.stamp, source: url)
                openTiming = OpenTiming(fileName: url.lastPathComponent, pageCount: opened.deck.slides.count,
                                        requestedAt: requestedAt,
                                        readAndConvert: max(0, loadedAt - requestedAt - opened.imagePreparation),
                                        imagePreparation: opened.imagePreparation, uiInstalledAt: OpenTiming.now)
                NSDocumentController.shared.noteNewRecentDocumentURL(url)
                refreshRecent()
            } catch {
                guard operation == request, !work.isCancelled else { return }
                self.error = "无法打开「\(url.lastPathComponent)」。\n\(error.localizedDescription)"
            }
        }
    }

    func recordFirstDraw(for editor: UUID, at time: Double, imageTime: Double) {
        guard editor == identity, let timing = openTiming, timing.firstDraw == nil,
              time >= timing.uiInstalledAt else { return }
        openTiming?.firstDraw = time - timing.uiInstalledAt
        openTiming?.displayImagePreparation = imageTime
        DispatchQueue.main.async { [weak self] in
            guard let self, self.identity == editor else { return }
            self.openTiming?.readyAfterDraw = OpenTiming.now - timing.requestedAt
        }
    }

    func cancelOpening() {
        reader?.cancel()
        reader = nil
        operation = nil
        opening = false
    }

    @discardableResult
    func replace(with deck: Deck, at url: URL? = nil, markEdited: Bool = false) -> Bool {
        guard confirmReplacement() else { return false }
        install(deck, at: url, markEdited: markEdited)
        return true
    }

    func newDeck() {
        if replace(with: Deck()) { cancelOpening() }
    }

    func resetAfterClose() {
        cancelOpening()
        install(Deck(), at: nil, markEdited: false, isClosing: true)
    }

    private func install(_ deck: Deck, at url: URL?, markEdited: Bool, stamp: NativeDocumentStamp? = nil,
                         source: URL? = nil, isClosing: Bool = false) {
        undoManager.removeAllActions()
        document = SlidesDocument(deck: deck)
        fileURL = url
        sourceURL = source
        hasDocument = !isClosing
        screen = isClosing ? .home : .editor
        savedStamp = stamp ?? url.flatMap { NativeDocumentStamp(at: $0) }
        let remembered = url.flatMap { positions.page(for: $0) }
        activePageID = deck.slides.first(where: { $0.id == remembered })?.id ?? deck.slides.first?.id
        savedDeck = markEdited ? nil : deck
        openTiming = nil
        error = nil
        identity = UUID()
        statusChanged?()
    }

    @discardableResult
    func save(asCopy: Bool = false) -> Bool {
        guard hasDocument, endTextEditing() else { return false }
        let destination: URL
        if let fileURL, !asCopy {
            destination = fileURL
        } else {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.kongSlides]
            panel.canCreateDirectories = true
            panel.nameFieldStringValue = name
            guard panel.runModal() == .OK, let url = panel.url else { return false }
            destination = url
        }

        do {
            let scoped = destination.startAccessingSecurityScopedResource()
            defer { if scoped { destination.stopAccessingSecurityScopedResource() } }
            if fileURL?.resolvingSymlinksInPath().standardizedFileURL == destination.resolvingSymlinksInPath().standardizedFileURL,
               savedStamp != NativeDocumentStamp(at: destination) {
                if asCopy { throw NativeDocumentChanged.externalModification }
                return resolveSaveConflict(destination)
            }
            try document.writeNative(to: destination)
            savedStamp = NativeDocumentStamp(at: destination)
            fileURL = destination
            savedDeck = document.deck
            if let page = activePageID, document.deck.slides.contains(where: { $0.id == page }) {
                positions.remember(page, for: destination)
            }
            self.error = nil
            statusChanged?()
            NSDocumentController.shared.noteNewRecentDocumentURL(destination)
            refreshRecent()
            return true
        } catch {
            self.error = "无法保存「\(destination.lastPathComponent)」。\n\(error.localizedDescription)"
            return false
        }
    }

    private func resolveSaveConflict(_ url: URL) -> Bool {
        let alert = NSAlert()
        alert.messageText = "磁盘上的课件已有变化"
        alert.informativeText = "可以把当前修改另存为副本，也可以放弃当前修改并重新载入磁盘版本。"
        alert.addButton(withTitle: "另存为…")
        alert.addButton(withTitle: "取消").keyEquivalent = "\u{1b}"
        alert.addButton(withTitle: "放弃修改并重新载入")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return save(asCopy: true)
        case .alertThirdButtonReturn: open(url, discardEditsToReload: true); return false
        default: return false
        }
    }

    private func endTextEditing() -> Bool {
        guard let window = NSApp.keyWindow, window.firstResponder is NSTextView else { return true }
        return window.makeFirstResponder(nil)
    }

    func confirmReplacement() -> Bool {
        guard endTextEditing() else { return false }
        guard isEdited else { return true }
        let alert = NSAlert()
        alert.messageText = "要保存对「\(name)」的修改吗？"
        alert.informativeText = "保存后可继续打开其他课件或关闭编辑窗口。"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消").keyEquivalent = "\u{1b}"
        alert.addButton(withTitle: "不保存")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return save()
        case .alertThirdButtonReturn: return true
        default: return false
        }
    }
}
