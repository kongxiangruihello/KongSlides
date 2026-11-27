import AppKit
import SwiftUI

struct SlideOverview: View {
    let deck: Deck
    let current: UUID
    let imageCache: SlideImageCache
    let open: (UUID) -> Void
    let reorder: (UUID, UUID) -> Bool
    let setBackup: (Bool, Set<UUID>) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selection: SidebarPageSelection?

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Text("幻灯片总览").font(.headline)
                Spacer()
                if let ids = selection?.selected, !ids.isEmpty {
                    Button("设为备用页") { setBackup(true, ids) }
                    Button("设为正片") { setBackup(false, ids) }
                }
                Button("打开选中页") {
                    if let page = selection?.current { open(page); dismiss() }
                }.keyboardShortcut(.defaultAction)
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 165), spacing: 12)], spacing: 12) {
                    ForEach(Array(deck.slides.enumerated()), id: \.element.id) { index, slide in
                        Button { select(slide.id) } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                SlideSurface(slide: slide, images: deck.images, canvas: deck.pageCanvas, imageCache: imageCache, thumbnail: true)
                                Text("\(index + 1)  \(slide.title)" + (slide.isBackup ? " · 备用" : ""))
                                    .font(.caption).lineLimit(1)
                            }
                            .padding(5)
                            .background(selection?.selected.contains(slide.id) == true ? Color.accentColor.opacity(0.2) : Color.clear)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .draggable(slide.id.uuidString)
                        .dropDestination(for: String.self) { values, _ in
                            guard values.count == 1, let value = values.first, let source = UUID(uuidString: value) else { return false }
                            return reorder(source, slide.id)
                        }
                    }
                }
                .padding(3)
            }
        }
        .padding(18)
        .frame(minWidth: 780, minHeight: 480)
        .onAppear { selection = SidebarPageSelection(current: current, selected: [current], anchor: current) }
    }

    private func select(_ id: UUID) {
        let flags = NSEvent.modifierFlags
        let mode: SidebarPageSelection.Click = flags.contains(.shift) ? .range : flags.contains(.command) ? .toggle : .single
        selection?.click(id, in: deck.slides.map(\.id), mode: mode)
    }
}
