import AppKit
import SwiftUI

struct HomeFileSelection: Identifiable {
    let url: URL
    var id: URL { url }
}

struct HomeFilePreview: View {
    let url: URL
    let cached: HomeLibrary.Preview?
    let open: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var preview: HomeLibrary.Preview?
    @State private var loading = false
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(url.deletingPathExtension().lastPathComponent).font(.headline)
            Text(url.deletingLastPathComponent().path)
                .font(.caption).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
            if let item = preview ?? cached {
                HomeCover(data: item.coverPNG ?? (cached == nil ? item.thumbnailPNG : nil)).frame(width: 292, height: 159)
                Text("\(item.total) 页 · \(item.backups) 张备用页")
                if let cached { Text("上次停留在第 \(cached.page) 页").foregroundStyle(.secondary) }
            }
            if let failure { Text(failure).foregroundStyle(.secondary) }
            if loading { ProgressView("正在读取课件预览…") }
            HStack {
                if !loading && (preview ?? cached)?.coverPNG == nil {
                    Button("读取预览", action: load).disabled(!FileManager.default.fileExists(atPath: url.path))
                }
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("打开课件") { dismiss(); open() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 410)
        .onAppear { if cached == nil { load() } }
    }

    private func load() {
        loading = true
        Task {
            defer { loading = false }
            do {
                let url = self.url
                preview = try await Task.detached(priority: .utility) {
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    let deck: Deck
                    if url.pathExtension.lowercased() == "kongslides" { deck = try SlidesDocument.readNative(url).deck }
                    else { deck = try PowerPoint.readForEditor(url).deck }
                    guard let slide = deck.slides.first else { throw CocoaError(.fileReadCorruptFile) }
                    return HomeLibrary.Preview(title: slide.title, section: slide.section, page: 1,
                        pageID: slide.id, total: deck.slides.count, backups: deck.slides.count(where: \.isBackup),
                        pendingRepairs: 0, thumbnailPNG: nil,
                        coverPNG: HomeThumbnail.render(slide, images: deck.images, canvas: deck.pageCanvas),
                        preflightPages: nil)
                }.value
            } catch { failure = error.localizedDescription }
        }
    }
}

struct HomeCover: View {
    let data: Data?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7).fill(.secondary.opacity(0.12))
            if let data, let picture = NSImage(data: data) {
                Image(nsImage: picture).resizable().scaledToFit()
            } else {
                Image(systemName: "rectangle.on.rectangle").foregroundStyle(.secondary)
            }
        }
        .clipShape(.rect(cornerRadius: 7))
        .accessibilityHidden(true)
    }
}
