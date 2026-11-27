import AppKit
import SwiftUI

struct RecoverySnapshot: Codable {
    let savedAt: Date
    let name: String
    let deck: Deck
}

struct RecoveryEntry: Identifiable {
    var id: UUID
    let url: URL
    let name: String
    let savedAt: Date
}

enum RecoveryFiles {
    static let queue = DispatchQueue(label: "KongSlides.DocumentRecovery", qos: .utility)
    static let directory = URL.applicationSupportDirectory.appendingPathComponent("KongSlides/Recovery", isDirectory: true)

    static func write(_ snapshot: RecoverySnapshot, id: UUID, in folder: URL = directory) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(snapshot.deck.validated())
        let package = folder.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try data.write(to: package.appendingPathComponent("Deck.kongslides"), options: .atomic)
        let metadata = RecoveryMetadata(name: snapshot.name, savedAt: snapshot.savedAt)
        try JSONEncoder().encode(metadata).write(to: package.appendingPathComponent("Metadata.json"), options: .atomic)
    }

    static func entries(in folder: URL = directory) -> [RecoveryEntry] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])) ?? []
        return urls.compactMap { url -> RecoveryEntry? in
            guard let id = UUID(uuidString: url.lastPathComponent),
                  let info = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  info.isDirectory == true, info.isSymbolicLink == false,
                  let attributes = try? Data(contentsOf: url.appendingPathComponent("Metadata.json")),
                  let metadata = try? JSONDecoder().decode(RecoveryMetadata.self, from: attributes) else { return nil }
            return RecoveryEntry(id: id, url: url, name: metadata.name, savedAt: metadata.savedAt)
        }.sorted { $0.savedAt > $1.savedAt }
    }

    static func read(_ entry: RecoveryEntry) throws -> Deck {
        let data = try Data(contentsOf: entry.url.appendingPathComponent("Deck.kongslides"))
        return try JSONDecoder().decode(Deck.self, from: data).validated()
    }

    static func remove(_ id: UUID, in folder: URL = directory) throws {
        let path = folder.appendingPathComponent(id.uuidString, isDirectory: true)
        if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) }
    }
}

private struct RecoveryMetadata: Codable {
    let name: String
    let savedAt: Date
}

@MainActor
final class RecoverySession {
    static let shared = RecoverySession()
    private var current = Set<UUID>()
    private var offered = false

    func write(_ snapshot: RecoverySnapshot, id: UUID) {
        current.insert(id)
        RecoveryFiles.queue.async {
            do { try RecoveryFiles.write(snapshot, id: id) }
            catch { NSLog("KongSlides recovery copy failed: %@", error.localizedDescription) }
        }
    }

    func close(_ id: UUID) {
        guard current.remove(id) != nil else { return }
        RecoveryFiles.queue.async { try? RecoveryFiles.remove(id) }
    }

    func finish() {
        let ids = current
        RecoveryFiles.queue.sync { for id in ids { try? RecoveryFiles.remove(id) } }
        current.removeAll()
    }

    func previousEntries() -> [RecoveryEntry] {
        let ids = current
        return RecoveryFiles.queue.sync { RecoveryFiles.entries().filter { !ids.contains($0.id) } }
    }

    func shouldOffer() -> Bool {
        guard !offered else { return false }
        offered = true
        return !previousEntries().isEmpty
    }
}

struct RecoveryWindowObserver: NSViewRepresentable {
    let close: () -> Void

    func makeNSView(context: Context) -> ObserverView { ObserverView() }
    func updateNSView(_ view: ObserverView, context: Context) { view.close = close }

    final class ObserverView: NSView {
        var close: (() -> Void)?

        override func viewDidMoveToWindow() {
            NotificationCenter.default.removeObserver(self)
            if let window {
                NotificationCenter.default.addObserver(self, selector: #selector(willClose(_:)),
                                                       name: NSWindow.willCloseNotification, object: window)
            }
        }

        @objc private func willClose(_ note: Notification) { close?() }
        deinit { NotificationCenter.default.removeObserver(self) }
    }
}

struct RecoveryBrowser: View {
    let open: (Deck, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [RecoveryEntry] = []
    @State private var selected: UUID?
    @State private var preview: Deck?
    @State private var error: String?
    @State private var remove = false

    private var entry: RecoveryEntry? { entries.first { $0.id == selected } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("课件恢复").font(.title2.weight(.semibold))
            if entries.isEmpty {
                ContentUnavailableView("没有待恢复的课件", systemImage: "clock.arrow.circlepath")
            } else {
                HStack {
                    List(selection: $selected) {
                        ForEach(entries) { entry in
                            VStack(alignment: .leading) {
                                Text(entry.name)
                                Text(entry.savedAt, format: .dateTime.month().day().hour().minute())
                                    .font(.caption).foregroundStyle(.secondary)
                            }.tag(entry.id)
                        }
                    }.frame(width: 235)
                    if let preview, let first = preview.slides.first {
                        VStack {
                            SlideSurface(slide: first, images: preview.images, canvas: preview.pageCanvas)
                                .frame(maxHeight: 295)
                            Text("\(preview.slides.count) 页 · \(preview.images.count) 张嵌入图片")
                                .font(.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity)
                    }
                }
            }
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Button("删除所选恢复副本…", role: .destructive) { remove = true }.disabled(entry == nil)
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("打开为新课件") {
                    if let entry, let preview { open(preview, entry.name); dismiss() }
                }.disabled(preview == nil).keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(minWidth: 720, minHeight: 400)
        .onAppear { reload() }
        .task(id: selected) {
            preview = nil
            error = nil
            guard let entry else { return }
            do {
                let loaded = try await Task.detached { try RecoveryFiles.read(entry) }.value
                if !Task.isCancelled && selected == entry.id { preview = loaded }
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
        .alert("删除这个恢复副本？", isPresented: $remove) {
            Button("删除", role: .destructive) {
                guard let entry else { return }
                do { try RecoveryFiles.remove(entry.id); reload() }
                catch { self.error = error.localizedDescription }
            }
            Button("取消", role: .cancel) {}
        }
    }

    private func reload() {
        preview = nil
        entries = RecoverySession.shared.previousEntries()
        selected = entries.first?.id
    }
}
