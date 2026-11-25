import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

@main
struct KongSlidesApp: App {
    var body: some Scene {
        DocumentGroup(newDocument: SlidesDocument()) { file in
            EditorView(document: file.$document)
                .frame(minWidth: 1040, minHeight: 660)
                .tint(Color(nsColor: Palette.color(Palette.indigo)))
        }
    }
}

struct SlideSurface: View {
    let slide: Slide
    let images: [UUID: Data]
    var omittedObject: UUID? = nil

    var body: some View {
        Canvas { graphics, size in
            graphics.withCGContext { context in
                var visible = slide
                if let omittedObject { visible.objects.removeAll { $0.id == omittedObject } }
                context.translateBy(x: 0, y: size.height)
                context.scaleBy(x: size.width / Deck.size.width, y: -size.height / Deck.size.height)
                SlideDrawing.draw(visible, images: images, in: context)
            }
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .accessibilityLabel(slide.title)
    }
}

struct EditorView: View {
    @Binding var document: SlidesDocument
    @State private var slideID: UUID?
    @State private var objectID: UUID?
    @State private var editingID: UUID?
    @State private var linkedError: String?
    @State private var importNotice: String?
    @State private var importing = false
    @State private var showNotes = true
    @State private var search = ""
    @State private var presenter = PresentationController()
    @FocusState private var canvasTextFocused: Bool

    private var deck: Deck { document.deck }
    private var index: Int { deck.slides.firstIndex { $0.id == slideID } ?? 0 }
    private var slide: Slide { deck.slides[index] }
    private var selection: Int? { slide.objects.firstIndex { $0.id == objectID } }

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            HStack(spacing: 0) {
                sidebar.frame(width: 206)
                Divider()
                VStack(spacing: 0) {
                    workspace
                    if showNotes {
                        Divider()
                        notes
                    }
                }
                Divider()
                inspector.frame(width: 230)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: slide.id) { objectID = nil; editingID = nil }
        .onChange(of: objectID) { if editingID != objectID { editingID = nil } }
        .onChange(of: canvasTextFocused) { if !canvasTextFocused { editingID = nil } }
        .alert("操作未完成", isPresented: Binding(
            get: { linkedError != nil }, set: { if !$0 { linkedError = nil } }
        )) {
            Button("好", role: .cancel) { linkedError = nil }
        } message: { Text(linkedError ?? "") }
        .alert("PPTX 已导入", isPresented: Binding(
            get: { importNotice != nil }, set: { if !$0 { importNotice = nil } }
        )) {
            Button("好", role: .cancel) { importNotice = nil }
        } message: { Text(importNotice ?? "") }
    }

    private var controls: some View {
        HStack(spacing: 13) {
            HStack(spacing: 8) {
                Image(systemName: "rectangle.on.rectangle").foregroundStyle(Color.accentColor)
                Text("KongSlides").font(.headline)
            }
            Divider().frame(height: 21)
            Menu {
                Button("空白页") { addSlide(Slide()) }.keyboardShortcut("n", modifiers: [.command, .shift])
                Button("标题页") { addSlide(.titleSlide("新章节", subtitle: "输入副标题")) }
                Button("原文与解读") { addSlide(.readingSlide()) }
            } label: { Label("新建页", systemImage: "plus.rectangle") }
            .fixedSize()
            Button { addObject(SlideObject()) } label: { Label("文字", systemImage: "textformat") }
            Button(action: addImage) { Label("图片", systemImage: "photo") }
            Button {
                addObject(SlideObject(kind: .rectangle, x: 110, y: 170,
                                      width: 220, height: 100, color: Palette.indigo))
            } label: { Label("形状", systemImage: "rectangle") }
            Spacer(minLength: 3)
            Button {
                showNotes.toggle()
            } label: { Label("讲稿", systemImage: showNotes ? "note.text.badge.minus" : "note.text") }
            Menu {
                Button("导入 PPTX 到当前课件…", action: importPowerPoint).disabled(importing)
                Divider()
                Button("导出可编辑 PPTX…") { export(.powerPoint) }
                Button("导出投影 PDF…") { export(.pdf) }
            } label: { Label(importing ? "正在导入" : "交换文件", systemImage: "arrow.left.arrow.right") }
            .fixedSize()
            Button {
                presenter.start(deck: deck, at: index)
            } label: { Label("放映", systemImage: "play.fill") }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: [.command, .option])
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("幻灯片").font(.headline)
                Spacer()
                Text("\(deck.slides.count) 页").monospacedDigit().foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            TextField("搜索标题、正文或讲稿", text: $search)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 12)
            List(selection: Binding<UUID?>(
                get: { slide.id }, set: { if let id = $0 { slideID = id } }
            )) {
                ForEach(filteredSlides) { row in
                    slideRow(row).tag(row.id)
                }
                .onMove(perform: search.isEmpty ? reorder : nil)
            }
            .listStyle(.sidebar)
        }
        .padding(.top, 16)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var filteredSlides: [Slide] {
        guard !search.isEmpty else { return deck.slides }
        return deck.slides.filter { row in
            row.section.localizedCaseInsensitiveContains(search) ||
                row.speakerNotes.localizedCaseInsensitiveContains(search) ||
                row.objects.contains { $0.kind == .text && $0.text.localizedCaseInsensitiveContains(search) }
        }
    }

    private func slideRow(_ row: Slide) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            let position = deck.slides.firstIndex { $0.id == row.id } ?? 0
            if !row.section.isEmpty && (position == 0 || deck.slides[position - 1].section != row.section) {
                Text(row.section).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            SlideSurface(slide: row, images: deck.images)
                .clipShape(.rect(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.secondary.opacity(0.24)))
                .accessibilityHidden(true)
            HStack(spacing: 7) {
                Text(String(format: "%02d", position + 1)).monospacedDigit().foregroundStyle(.secondary)
                Text(row.title).lineLimit(1)
            }
            .font(.caption)
        }
        .padding(.vertical, 6)
        .contextMenu {
            Button("复制此页") { duplicateSlide(row.id) }
            Button("上移一页") { moveSlide(row.id, delta: -1) }.disabled(row.id == deck.slides.first?.id)
            Button("下移一页") { moveSlide(row.id, delta: 1) }.disabled(row.id == deck.slides.last?.id)
            if !row.section.isEmpty {
                Divider()
                Button("上移整章") { moveSection(row.id, delta: -1) }
                    .disabled(adjacentSection(row.id, delta: -1) == nil || !search.isEmpty)
                Button("下移整章") { moveSection(row.id, delta: 1) }
                    .disabled(adjacentSection(row.id, delta: 1) == nil || !search.isEmpty)
            }
            Button("删除此页", role: .destructive) { deleteSlide(row.id) }
        }
    }

    private var workspace: some View {
        GeometryReader { geometry in
            let scale = max(0.1, min((geometry.size.width - 48) / Deck.size.width,
                                     (geometry.size.height - 48) / Deck.size.height))
            ZStack {
                Color(nsColor: .underPageBackgroundColor)
                    .onTapGesture { objectID = nil; editingID = nil }
                ZStack(alignment: .topLeading) {
                    SlideSurface(slide: slide, images: deck.images, omittedObject: editingID)
                        .onTapGesture { objectID = nil; editingID = nil }
                    ForEach(slide.objects) { object in
                        objectOverlay(object, scale: scale)
                    }
                }
                .frame(width: Deck.size.width * scale, height: Deck.size.height * scale)
                .clipped()
                .coordinateSpace(name: "slideCanvas")
                .shadow(color: .black.opacity(0.15), radius: 12, y: 5)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func objectOverlay(_ object: SlideObject, scale: CGFloat) -> some View {
        let width = CGFloat(object.width) * scale
        let height = CGFloat(object.height) * scale
        if editingID == object.id {
            TextEditor(text: objectBinding(object.id, \.text, fallback: ""))
                .font(.system(size: object.fontSize * scale, weight: object.bold ? .bold : .regular))
                .foregroundStyle(Color(nsColor: Palette.color(object.color)))
                .scrollContentBackground(.hidden)
                .background(Color(nsColor: Palette.color(slide.background)))
                .focused($canvasTextFocused)
                .onAppear { canvasTextFocused = true }
                .onExitCommand { editingID = nil }
                .frame(width: width, height: height)
                .overlay(Rectangle().strokeBorder(Color.accentColor, lineWidth: 2).allowsHitTesting(false))
                .position(x: object.x * scale + width / 2, y: object.y * scale + height / 2)
                .zIndex(1)
        } else {
            ObjectHitArea(object: object, selected: objectID == object.id, scale: scale,
                          slideBackground: slide.background, images: deck.images,
                          select: { objectID = object.id },
                          edit: {
                              objectID = object.id
                              if object.kind == .text { editingID = object.id }
                          },
                          move: { offset in
                              guard let i = slide.objects.firstIndex(where: { $0.id == object.id }) else { return }
                              var updated = slide
                              updated.objects[i].x = (object.x + offset.width / scale).clamped(-960...960)
                              updated.objects[i].y = (object.y + offset.height / scale).clamped(-540...540)
                              document.deck.slides[index] = updated
                          })
                .frame(width: width, height: height)
                .position(x: object.x * scale + width / 2, y: object.y * scale + height / 2)
        }
    }

    private var notes: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Label("逐字讲稿", systemImage: "note.text").font(.headline)
                Spacer()
                Text("第 \(index + 1) 页").font(.caption).foregroundStyle(.secondary)
            }
            TextEditor(text: slideBinding(\.speakerNotes))
                .font(.body)
                .scrollContentBackground(.hidden)
                .frame(height: 108)
                .accessibilityLabel("逐字讲稿")
        }
        .padding(12)
    }

    private var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("版面属性").font(.headline)
                TextField("章节名称", text: slideBinding(\.section))
                colorMenu("页背景", selection: slideBinding(\.background),
                          colors: [("米白", Palette.paper), ("纯白", "FFFFFF"), ("深蓝", Palette.ink), ("淡蓝", "EDF2FC")])
                Divider()
                if let selection {
                    let object = slide.objects[selection]
                    Text(object.label).font(.headline).lineLimit(2)
                    if object.kind == .text {
                        TextEditor(text: objectBinding(object.id, \.text, fallback: ""))
                            .frame(height: 82)
                            .border(.secondary.opacity(0.22))
                            .accessibilityLabel("文本框内容")
                        number("字号", object: object, key: \.fontSize, range: 8...200)
                        Toggle("粗体", isOn: objectBinding(object.id, \.bold, fallback: false))
                    }
                    if object.kind != .image {
                        colorMenu(object.kind == .text ? "文字颜色" : "填充颜色",
                                  selection: objectBinding(object.id, \.color, fallback: Palette.ink),
                                  colors: [("墨黑", Palette.ink), ("靛蓝", Palette.indigo), ("砖红", "A34E42"),
                                           ("墨绿", "286B61"), ("纯白", "FFFFFF")])
                    }
                    Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 10) {
                        GridRow {
                            number("X", object: object, key: \.x, range: -960...960)
                            number("Y", object: object, key: \.y, range: -540...540)
                        }
                        GridRow {
                            number("宽", object: object, key: \.width, range: 1...1920)
                            number("高", object: object, key: \.height, range: 1...1080)
                        }
                    }
                    HStack {
                        Button("置顶") { changeLayer(object.id, front: true) }
                        Button("置底") { changeLayer(object.id, front: false) }
                    }
                    Button("删除对象", role: .destructive) { removeObject(object.id) }
                }
                if !slide.objects.isEmpty {
                    Divider()
                    Text("对象").font(.headline)
                    ForEach(slide.objects.reversed()) { object in
                        Button {
                            objectID = object.id
                        } label: {
                            Label(object.label, systemImage: object.kind == .text ? "textformat" :
                                    object.kind == .image ? "photo" : "rectangle")
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .padding(5)
                        .background(objectID == object.id ? Color.accentColor.opacity(0.12) : .clear,
                                    in: .rect(cornerRadius: 4))
                    }
                }
            }
            .padding(14)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func number(_ label: String, object: SlideObject,
                        key: WritableKeyPath<SlideObject, Double>, range: ClosedRange<Double>) -> some View {
        let binding = objectBinding(object.id, key, fallback: object[keyPath: key])
        return HStack(spacing: 4) {
            Text(label).foregroundStyle(.secondary)
            TextField(label, value: Binding(
                get: { binding.wrappedValue },
                set: { binding.wrappedValue = $0.clamped(range) }
            ), format: .number.precision(.fractionLength(0...1)))
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .frame(minWidth: 52)
        }
    }

    private func colorMenu(_ title: String, selection: Binding<String>,
                           colors: [(String, String)]) -> some View {
        Picker(title, selection: selection) {
            ForEach(colors, id: \.1) { color in Text(color.0).tag(color.1) }
        }
    }

    private func slideBinding<Value>(_ key: WritableKeyPath<Slide, Value>) -> Binding<Value> {
        Binding(get: { slide[keyPath: key] }, set: { document.deck.slides[index][keyPath: key] = $0 })
    }

    private func objectBinding<Value>(_ id: UUID, _ key: WritableKeyPath<SlideObject, Value>,
                                      fallback: Value) -> Binding<Value> {
        Binding(
            get: { slide.objects.first { $0.id == id }?[keyPath: key] ?? fallback },
            set: { value in
                guard let i = slide.objects.firstIndex(where: { $0.id == id }) else { return }
                document.deck.slides[index].objects[i][keyPath: key] = value
            }
        )
    }

    private func addSlide(_ newSlide: Slide) {
        var next = newSlide
        next.section = slide.section
        document.deck.slides.insert(next, at: index + 1)
        slideID = next.id
    }

    private func duplicateSlide(_ id: UUID) {
        guard let position = deck.slides.firstIndex(where: { $0.id == id }) else { return }
        var copy = deck.slides[position]
        copy.id = UUID()
        document.deck.slides.insert(copy, at: position + 1)
        slideID = copy.id
    }

    private func deleteSlide(_ id: UUID) {
        guard let position = deck.slides.firstIndex(where: { $0.id == id }) else { return }
        var updated = deck
        updated.slides.remove(at: position)
        if updated.slides.isEmpty { updated.slides = [Slide()] }
        if slide.id == id { slideID = updated.slides[min(position, updated.slides.count - 1)].id }
        document.deck = (try? updated.validated()) ?? updated
    }

    private func moveSlide(_ id: UUID, delta: Int) {
        guard let position = deck.slides.firstIndex(where: { $0.id == id }),
              deck.slides.indices.contains(position + delta) else { return }
        let current = slide.id
        document.deck.slides.swapAt(position, position + delta)
        slideID = current
    }

    private func reorder(from offsets: IndexSet, to destination: Int) {
        let current = slide.id
        document.deck.slides.move(fromOffsets: offsets, toOffset: destination)
        slideID = current
    }

    private func addObject(_ object: SlideObject) {
        document.deck.slides[index].objects.append(object)
        objectID = object.id
    }

    private func changeLayer(_ id: UUID, front: Bool) {
        guard let position = slide.objects.firstIndex(where: { $0.id == id }) else { return }
        var updated = slide
        let object = updated.objects.remove(at: position)
        updated.objects.insert(object, at: front ? updated.objects.count : 0)
        document.deck.slides[index] = updated
    }

    private func removeObject(_ id: UUID) {
        var updated = deck
        updated.slides[index].objects.removeAll { $0.id == id }
        if objectID == id { objectID = nil }
        document.deck = (try? updated.validated()) ?? updated
    }

    private func moveSection(_ id: UUID, delta: Int) {
        guard let source = sectionRange(id),
              let adjacent = adjacentSection(id, delta: delta) else { return }
        let current = slide.id
        document.deck.slides.move(fromOffsets: IndexSet(integersIn: source),
                                  toOffset: delta < 0 ? adjacent.lowerBound : adjacent.upperBound)
        slideID = current
    }

    private func sectionRange(_ id: UUID) -> Range<Int>? {
        guard let position = deck.slides.firstIndex(where: { $0.id == id }) else { return nil }
        let section = deck.slides[position].section
        var first = position
        var last = position + 1
        while first > 0 && deck.slides[first - 1].section == section { first -= 1 }
        while last < deck.slides.count && deck.slides[last].section == section { last += 1 }
        return first..<last
    }

    private func adjacentSection(_ id: UUID, delta: Int) -> Range<Int>? {
        guard let range = sectionRange(id) else { return nil }
        let boundary = delta < 0 ? range.lowerBound - 1 : range.upperBound
        guard deck.slides.indices.contains(boundary) else { return nil }
        return sectionRange(deck.slides[boundary].id)
    }

    private func addImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = PhotoStorage.thumbnail(source),
                  let png = PhotoStorage.png(image) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let scale = min(460.0 / Double(image.width), 295.0 / Double(image.height), 1.0)
            let id = UUID()
            let object = SlideObject(kind: .image, x: 135, y: 150,
                                     width: max(1, Double(image.width) * scale),
                                     height: max(1, Double(image.height) * scale), imageID: id)
            var updated = deck
            updated.images[id] = png
            updated.slides[index].objects.append(object)
            document.deck = updated
            objectID = object.id
        } catch { linkedError = "无法读取这张图片。\n\(error.localizedDescription)" }
    }

    private func importPowerPoint() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [ExportType.powerPoint.contentType]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importing = true
        Task { @MainActor in
            defer { importing = false }
            do {
                let imported = try await Task.detached(priority: .userInitiated) {
                    try PowerPoint.read(url) { data in
                        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                              let image = PhotoStorage.thumbnail(source) else { return nil }
                        return PhotoStorage.png(image)
                    }
                }.value
                var updated = deck
                let title = url.deletingPathExtension().lastPathComponent
                updated.slides.append(contentsOf: imported.deck.slides.map { original in
                    var copy = original
                    copy.section = title
                    return copy
                })
                updated.images.merge(imported.deck.images, uniquingKeysWith: { current, _ in current })
                document.deck = updated
                search = ""
                slideID = imported.deck.slides.first?.id

                let total = imported.deck.slides.count
                let pages = imported.approximatedSlides
                if pages.isEmpty {
                    importNotice = "已将 \(total) 页追加到当前课件。请核对中文字体和断行。"
                } else {
                    let list = pages.prefix(24).map(String.init).joined(separator: "、")
                    let suffix = pages.count > 24 ? "等 \(pages.count) 页" : "页"
                    importNotice = "已将 \(total) 页追加到当前课件。源文件第 \(list) \(suffix)含有近似转换或跳过的内容，请核对原片。"
                }
            } catch {
                linkedError = "无法导入这份 PPTX。\n\(error.localizedDescription)"
            }
        }
    }

    private func export(_ type: ExportType) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type.contentType]
        panel.nameFieldStringValue = slide.title + "." + type.rawValue
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            switch type {
            case .pdf: try SlideDrawing.pdf(deck, to: url)
            case .powerPoint: try PowerPoint.write(deck, to: url)
            }
        } catch { linkedError = error.localizedDescription }
    }
}

private enum PhotoStorage {
    static func thumbnail(_ source: CGImageSource) -> CGImage? {
        CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 2048
        ] as CFDictionary)
    }

    static func png(_ image: CGImage) -> Data? {
        guard let data = CFDataCreateMutable(nil, 0),
              let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}

private enum ExportType: String {
    case pdf
    case powerPoint = "pptx"
    var contentType: UTType {
        switch self {
        case .pdf: .pdf
        case .powerPoint: UTType(filenameExtension: rawValue) ?? .data
        }
    }
}

private struct ObjectHitArea: View {
    let object: SlideObject
    let selected: Bool
    let scale: CGFloat
    let slideBackground: String
    let images: [UUID: Data]
    let select: () -> Void
    let edit: () -> Void
    let move: (CGSize) -> Void
    @GestureState private var translation: CGSize? = nil

    var body: some View {
        Rectangle()
            .fill(.clear)
            .contentShape(Rectangle())
            .overlay {
                if translation != nil {
                    Canvas { graphics, _ in
                        var local = object
                        local.x = 0
                        local.y = 0
                        graphics.withCGContext { context in
                            context.translateBy(x: 0, y: Deck.size.height * scale)
                            context.scaleBy(x: scale, y: -scale)
                            SlideDrawing.draw(Slide(background: slideBackground, objects: [local]),
                                              images: images, in: context)
                        }
                    }
                    .clipped()
                }
                if selected || translation != nil {
                    Rectangle().strokeBorder(Color.accentColor, lineWidth: 2)
                }
            }
            .onTapGesture(count: 2, perform: edit)
            .onTapGesture(perform: select)
            .gesture(DragGesture(minimumDistance: 4, coordinateSpace: .named("slideCanvas"))
                .updating($translation) { drag, state, _ in state = drag.translation }
                .onEnded { drag in select(); move(drag.translation) })
            .offset(translation ?? .zero)
            .accessibilityLabel(object.label)
    }
}

private extension Double {
    func clamped(_ range: ClosedRange<Double>) -> Double {
        isFinite ? min(range.upperBound, max(range.lowerBound, self)) : range.lowerBound
    }
}
