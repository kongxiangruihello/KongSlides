import SwiftUI

struct DeckSnapshot: Identifiable {
    var id: URL { url }
    let url: URL
    let deck: Deck

    func restoring(_ selected: Set<UUID>, into current: Deck) throws -> Deck {
        var result = current
        var assets: [UUID: UUID] = [:]
        for page in deck.slides where selected.contains(page.id) {
            var restored = page
            restored.objects = page.objects.map { object in
                var copy = deck.pageCanvas.fitting(object, into: current.pageCanvas)
                if let old = object.imageID, let bytes = deck.images[old] {
                    let target = assets[old] ?? (current.images[old].map { $0 != bytes } == true ? UUID() : old)
                    assets[old] = target
                    result.images[target] = bytes
                    copy.imageID = target
                }
                return copy
            }
            if let position = result.slides.firstIndex(where: { $0.id == page.id }) {
                result.slides[position] = restored
            } else {
                result.slides.append(restored)
            }
        }
        return try result.validated()
    }
}

struct DeckSnapshotView: View {
    let snapshot: DeckSnapshot
    let restore: (Set<UUID>?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<UUID> = []
    @State private var restoreAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(snapshot.url.deletingPathExtension().lastPathComponent).font(.headline)
            HStack {
                List(selection: $selected) {
                    ForEach(Array(snapshot.deck.slides.enumerated()), id: \.element.id) { index, slide in
                        Text("\(index + 1)  \(slide.title)").tag(slide.id)
                    }
                }.frame(minWidth: 210)
                if let page = snapshot.deck.slides.first(where: { selected.contains($0.id) }) {
                    SlideSurface(slide: page, images: snapshot.deck.images, canvas: snapshot.deck.pageCanvas)
                }
            }
            Text("按页面标识恢复；当前课件中没有的所选页会追加。可用 ⌘Z 撤销。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("关闭") { dismiss() }
                Button("恢复所选页") { restore(selected); dismiss() }.disabled(selected.isEmpty)
                Button("恢复整份…") { restoreAll = true }
            }
        }
        .padding(18)
        .frame(minWidth: 720, minHeight: 420)
        .alert("用快照替换当前课件内容？", isPresented: $restoreAll) {
            Button("替换", role: .destructive) { restore(nil); dismiss() }
            Button("取消", role: .cancel) {}
        }
    }
}
