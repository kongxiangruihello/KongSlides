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
            func remap(_ object: SlideObject) -> SlideObject {
                var copy = deck.pageCanvas.fitting(object, into: current.pageCanvas)
                if let old = object.imageID, let bytes = deck.images[old] {
                    let target = assets[old] ?? (current.images[old].map { $0 != bytes } == true ? UUID() : old)
                    assets[old] = target
                    result.images[target] = bytes
                    copy.imageID = target
                }
                return copy
            }
            restored.objects = page.objects.map(remap)
            if let backup = page.originalPDFPage {
                restored.originalPDFPage = .init(background: backup.background, objects: backup.objects.map(remap),
                                                 previousRepair: backup.previousRepair)
            }
            if let position = result.slides.firstIndex(where: { $0.id == page.id }) {
                result.slides[position] = restored
            } else {
                if let next = deck.slides.firstIndex(where: { $0.id == page.id })
                    .flatMap({ index in deck.slides.dropFirst(index + 1).first { next in
                        result.slides.contains { $0.id == next.id }
                    } }),
                   let destination = result.slides.firstIndex(where: { $0.id == next.id }) {
                    result.slides.insert(restored, at: destination)
                } else {
                    result.slides.append(restored)
                }
            }
        }
        return try result.validated()
    }
}

struct DeckSnapshotView: View {
    let snapshot: DeckSnapshot
    let current: Deck
    let restore: (Set<UUID>?, Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<UUID> = []
    @State private var restoreAll = false
    @State private var selectedChapter: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(snapshot.url.deletingPathExtension().lastPathComponent).font(.headline)
            HStack {
                List(selection: $selected) {
                    ForEach(Array(snapshot.deck.slides.enumerated()), id: \.element.id) { index, slide in
                        let existing = current.slides.first { $0.id == slide.id }
                        let tag = existing.map { $0 == slide ? "相同" : "有变更" } ?? "当前课件缺失"
                        Text("\(index + 1)  \(slide.title) · \(tag)").tag(slide.id)
                    }
                }.frame(width: 220)
                if let page = snapshot.deck.slides.first(where: { selected.contains($0.id) }) {
                    SlideChangePreview(before: current.slides.first { $0.id == page.id }, after: page,
                                       original: current, revised: snapshot.deck)
                } else {
                    ContentUnavailableView("选择要比较的页面", systemImage: "rectangle.split.2x1")
                }
            }
            Text("按页面标识恢复，修改可用 ⌘Z 撤销。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("关闭") { dismiss() }
                Menu("选择快照中的章节") {
                    ForEach(Array(Set(snapshot.deck.slides.map(\.section)).filter { !$0.isEmpty }.sorted()), id: \.self) { name in
                        Button(name) {
                            selectedChapter = name
                            selected = Set(snapshot.deck.slides.filter { $0.section == name }.map(\.id))
                        }
                    }
                }
                Button("恢复 \(selected.count) 页讲稿") { restore(selected, true); dismiss() }.disabled(selected.isEmpty)
                Button(selectedChapter == nil ? "恢复 \(selected.count) 页" : "恢复 1 章") { restore(selected, false); dismiss() }.disabled(selected.isEmpty)
                Button("恢复整份…") { restoreAll = true }
            }
        }
        .padding(18)
        .frame(minWidth: 720, minHeight: 420)
        .onChange(of: selected) {
            if let selectedChapter,
               selected != Set(snapshot.deck.slides.filter { $0.section == selectedChapter }.map(\.id)) {
                self.selectedChapter = nil
            }
        }
        .alert("用快照替换当前课件内容？", isPresented: $restoreAll) {
            Button("替换", role: .destructive) { restore(nil, false); dismiss() }
            Button("取消", role: .cancel) {}
        }
    }
}
