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
}

private enum NativeDocumentChanged: LocalizedError {
    case externalModification

    var errorDescription: String? { "文件已被其他应用或同步服务修改。请重新打开，或把当前课件另存为副本。" }
}

@MainActor @Observable
final class EditorFileSession {
    private(set) var document = SlidesDocument()
    private(set) var fileURL: URL?
    private(set) var identity = UUID()
    private(set) var activePageID: UUID?
    private(set) var opening = false
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

    init(positions: RecentSlidePositions = .init()) {
        self.positions = positions
        savedDeck = document.deck
        activePageID = document.deck.slides.first?.id
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
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.kongSlides, .slidePowerPoint] + [UTType(filenameExtension: "ppt")].compactMap { $0 }
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }

    func open(_ url: URL, discardEditsToReload: Bool = false) {
        guard url.isFileURL, ["kongslides", "pptx", "ppt"].contains(url.pathExtension.lowercased()),
              discardEditsToReload || url.standardizedFileURL != fileURL?.standardizedFileURL else { return }
        cancelOpening()
        let request = UUID()
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
            let imported = try PowerPoint.readForEditor(url) { completed, total in
                Task { @MainActor in
                    progress.completed = max(progress.completed, completed)
                    progress.total = total
                }
            }
            return OpenedDeck(deck: imported.deck)
        }
        reader = work
        Task {
            defer { if operation == request { cancelOpening() } }
            do {
                let opened = try await work.value
                guard operation == request, !work.isCancelled else { return }
                let destination = url.pathExtension.lowercased() == "kongslides" ? url : nil
                guard (discardEditsToReload || confirmReplacement()), operation == request, !work.isCancelled else { return }
                install(opened.deck, at: destination, markEdited: false, stamp: opened.stamp)
                NSDocumentController.shared.noteNewRecentDocumentURL(url)
            } catch {
                guard operation == request, !work.isCancelled else { return }
                self.error = "无法打开「\(url.lastPathComponent)」。\n\(error.localizedDescription)"
            }
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
        install(Deck(), at: nil, markEdited: false)
    }

    private func install(_ deck: Deck, at url: URL?, markEdited: Bool, stamp: NativeDocumentStamp? = nil) {
        undoManager.removeAllActions()
        document = SlidesDocument(deck: deck)
        fileURL = url
        savedStamp = stamp ?? url.flatMap { NativeDocumentStamp(at: $0) }
        let remembered = url.flatMap { positions.page(for: $0) }
        activePageID = deck.slides.first(where: { $0.id == remembered })?.id ?? deck.slides.first?.id
        savedDeck = markEdited ? nil : deck
        error = nil
        identity = UUID()
        statusChanged?()
    }

    @discardableResult
    func save(asCopy: Bool = false) -> Bool {
        guard endTextEditing() else { return false }
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
