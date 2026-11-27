import AppKit
import Observation
import UniformTypeIdentifiers

@MainActor @Observable
final class EditorFileSession {
    private(set) var document = SlidesDocument()
    private(set) var fileURL: URL?
    private(set) var identity = UUID()
    private(set) var opening = false
    private(set) var progress = ImportProgress()
    var error: String?

    @ObservationIgnored let undoManager = UndoManager()
    @ObservationIgnored var statusChanged: (() -> Void)?
    @ObservationIgnored private var savedDeck: Deck?
    @ObservationIgnored private var reader: Task<Deck, Error>?
    @ObservationIgnored private var operation: UUID?

    init() { savedDeck = document.deck }

    var name: String {
        fileURL?.deletingPathExtension().lastPathComponent ?? document.deck.importedTitle ?? "未命名课件"
    }

    var isEdited: Bool { document.deck != savedDeck }

    func edit(_ value: SlidesDocument) {
        guard document.deck != value.deck else { return }
        let previous = document
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

    func open(_ url: URL) {
        guard url.isFileURL, ["kongslides", "pptx", "ppt"].contains(url.pathExtension.lowercased()),
              url.standardizedFileURL != fileURL?.standardizedFileURL else { return }
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
                return try SlidesDocument.readNative(url).deck
            }
            return try PowerPoint.readForEditor(url) { completed, total in
                Task { @MainActor in
                    progress.completed = max(progress.completed, completed)
                    progress.total = total
                }
            }.deck
        }
        reader = work
        Task {
            defer { if operation == request { cancelOpening() } }
            do {
                let deck = try await work.value
                guard operation == request, !work.isCancelled else { return }
                let destination = url.pathExtension.lowercased() == "kongslides" ? url : nil
                guard confirmReplacement(), operation == request, !work.isCancelled else { return }
                install(deck, at: destination, markEdited: false)
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

    private func install(_ deck: Deck, at url: URL?, markEdited: Bool) {
        undoManager.removeAllActions()
        document = SlidesDocument(deck: deck)
        fileURL = url
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
            try document.writeNative(to: destination)
            fileURL = destination
            savedDeck = document.deck
            self.error = nil
            statusChanged?()
            NSDocumentController.shared.noteNewRecentDocumentURL(destination)
            return true
        } catch {
            self.error = "无法保存「\(destination.lastPathComponent)」。\n\(error.localizedDescription)"
            return false
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
