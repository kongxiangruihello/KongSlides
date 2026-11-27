import AppKit
import SwiftUI

struct EditorKeyMonitor: NSViewRepresentable {
    var handle: (NSEvent) -> Bool

    final class Coordinator {
        weak var view: NSView?
        var handle: (NSEvent) -> Bool
        var monitor: Any?

        init(handle: @escaping (NSEvent) -> Bool) { self.handle = handle }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(handle: handle) }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let coordinator = context.coordinator
        coordinator.view = view
        coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak coordinator] event in
            guard let coordinator, let window = coordinator.view?.window, event.window === window,
                  !(window.firstResponder is NSTextView), coordinator.handle(event) else { return event }
            return nil
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) { context.coordinator.handle = handle }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) { coordinator.stop() }
}

struct SlideResizeHandles: View {
    let frame: CGRect
    let scale: CGFloat
    let proportional: Bool
    let commit: (CGRect) -> Void
    @State private var preview: CGRect?

    var body: some View {
        let outline = preview ?? frame
        ZStack(alignment: .topLeading) {
            if preview != nil {
                Rectangle().strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [5, 3]))
                    .frame(width: outline.width * scale, height: outline.height * scale)
                    .position(x: outline.midX * scale, y: outline.midY * scale)
                    .allowsHitTesting(false)
            }
            ForEach(ResizeCorner.allCases, id: \.self) { corner in
                Rectangle().fill(.white)
                    .overlay(Rectangle().strokeBorder(Color.accentColor, lineWidth: 1.5))
                    .frame(width: 9, height: 9)
                    .padding(4)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("slideCanvas"))
                        .onChanged { value in preview = newFrame(corner, value.translation) }
                        .onEnded { value in
                            preview = nil
                            commit(newFrame(corner, value.translation))
                        })
                    .position(x: (corner.left ? outline.minX : outline.maxX) * scale,
                              y: (corner.top ? outline.minY : outline.maxY) * scale)
                    .accessibilityHidden(true)
            }
        }
    }

    private func newFrame(_ corner: ResizeCorner, _ delta: CGSize) -> CGRect {
        corner.resized(frame, translation: CGSize(width: delta.width / scale, height: delta.height / scale),
                       proportional: proportional)
    }
}

struct NotesFocusView: View {
    @Binding var document: SlidesDocument
    @Binding var slideID: UUID?
    @Binding var fontSize: Double
    @Environment(\.dismiss) private var dismiss
    @State private var continuous = false

    private var index: Int { document.deck.slides.firstIndex { $0.id == slideID } ?? 0 }
    private var slide: Slide { document.deck.slides[index] }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Text("逐字讲稿").font(.headline)
                Button("上一页") { go(-1) }.disabled(index == 0 || continuous)
                Button("下一页") { go(1) }.disabled(index + 1 >= document.deck.slides.count || continuous)
                Text("\(index + 1) / \(document.deck.slides.count)").monospacedDigit().foregroundStyle(.secondary)
                Spacer()
                Toggle("连续阅读", isOn: $continuous)
                Stepper("\(Int(fontSize)) 磅", value: $fontSize, in: 12...36)
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Divider()
            if continuous {
                ScrollViewReader { scroll in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 16) {
                            ForEach(Array(document.deck.slides.enumerated()), id: \.element.id) { offset, row in
                                VStack(alignment: .leading, spacing: 8) {
                                    Button("第 \(offset + 1) 页 · \(row.title)") {
                                        slideID = row.id
                                        continuous = false
                                    }.font(.headline).buttonStyle(.link)
                                    Text(row.speakerNotes.isEmpty ? "本页暂无讲稿" : row.speakerNotes)
                                        .font(.system(size: fontSize)).textSelection(.enabled)
                                    Divider()
                                }.id(row.id)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.onAppear { scroll.scrollTo(slide.id, anchor: .top) }
                }
            } else {
                HStack(alignment: .top, spacing: 20) {
                    VStack(alignment: .leading) {
                        SlideSurface(slide: slide, images: document.deck.images, canvas: document.deck.pageCanvas)
                        Text(slide.title).font(.headline)
                        Text(slide.section).foregroundStyle(.secondary)
                    }.frame(width: 250)
                    TextEditor(text: notesBinding(for: slide.id))
                        .font(.system(size: fontSize)).id(slide.id)
                        .accessibilityLabel("本页逐字讲稿")
                        .frame(maxHeight: .infinity)
                }
            }
        }
        .padding(18)
        .frame(minWidth: 820, minHeight: 560)
    }

    private func notesBinding(for id: UUID) -> Binding<String> {
        Binding(get: { document.deck.slides.first { $0.id == id }?.speakerNotes ?? "" },
                set: { text in
                    if let position = document.deck.slides.firstIndex(where: { $0.id == id }) {
                        document.deck.slides[position].speakerNotes = text
                    }
                })
    }

    private func go(_ delta: Int) {
        let next = index + delta
        if document.deck.slides.indices.contains(next) { slideID = document.deck.slides[next].id }
    }
}
