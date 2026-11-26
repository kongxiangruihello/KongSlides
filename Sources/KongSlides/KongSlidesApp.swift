import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

@main
struct KongSlidesApp: App {
    @NSApplicationDelegateAdaptor(AppLifecycle.self) private var lifecycle
    @AppStorage(SoftwareUpdate.automaticKey) private var automaticallyCheck = true

    var body: some Scene {
        DocumentGroup(newDocument: SlidesDocument()) { file in
            EditorView(document: file.$document)
                .frame(minWidth: 1040, minHeight: 660)
                .tint(Color(nsColor: Palette.color(Palette.indigo)))
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button("检查更新…") {
                    Task { await SoftwareUpdate.shared.check(manual: true) }
                }
                Toggle("自动检查更新", isOn: $automaticallyCheck)
            }
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
    @State private var selectedPageIDs: Set<UUID> = []
    @State private var collapsedSections: Set<UUID> = []
    @State private var pageCommands = false
    @State private var pendingDeletion: Set<UUID> = []
    @State private var notesFocus = false
    @AppStorage("speakerNotesFontSize") private var notesFontSize = 16.0
    @State private var notesHeight = 108.0
    @GestureState private var notesResize = 0.0
    @State private var objectID: UUID?
    @State private var editingID: UUID?
    @State private var linkedError: String?
    @State private var reviewMode: SlideReviewMode?
    @State private var preflightRows: [SlideReviewRow] = []
    @State private var preflightPageCount = 0
    @State private var checkingPreflight = false
    @State private var importing = false
    @State private var showNotes = true
    @State private var search = ""
    @State private var presenter = PresentationController()
    @FocusState private var canvasTextFocused: Bool

    private var deck: Deck { document.deck }
    private var index: Int { deck.slides.firstIndex { $0.id == slideID } ?? 0 }
    private var slide: Slide { deck.slides[index] }
    private var selectedPages: Set<UUID> { selectedPageIDs.intersection(deck.slides.map(\.id)) }
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
                    if let reviewMode {
                        Divider()
                        reviewPanel(reviewMode)
                    }
                }
                Divider()
                inspector.frame(width: 230)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .background(EditorKeyMonitor(handle: handleShortcut))
        .sheet(isPresented: $notesFocus, onDismiss: { selectedPageIDs = [slide.id] }) {
            NotesFocusView(document: $document, slideID: $slideID, fontSize: $notesFontSize)
        }
        .alert("删除 \(pendingDeletion.count) 页幻灯片？", isPresented: Binding(
            get: { !pendingDeletion.isEmpty }, set: { if !$0 { pendingDeletion = [] } }
        )) {
            Button("删除", role: .destructive) {
                deleteSlides(pendingDeletion)
                pendingDeletion = []
            }
            Button("取消", role: .cancel) { pendingDeletion = [] }
        } message: { Text("所选页面及其讲稿会一起移除。") }
        .onChange(of: slide.id) {
            if selection == nil { objectID = nil }
            editingID = nil
        }
        .onChange(of: objectID) { if editingID != objectID { editingID = nil } }
        .onChange(of: canvasTextFocused) { if !canvasTextFocused { editingID = nil } }
        .alert("操作未完成", isPresented: Binding(
            get: { linkedError != nil }, set: { if !$0 { linkedError = nil } }
        )) {
            Button("好", role: .cancel) { linkedError = nil }
        } message: { Text(linkedError ?? "") }

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
                Button("查看 PPTX 导入报告") { reviewMode = .imported }
                    .disabled(!deck.slides.contains { $0.importReport != nil })
                Divider()
                Button("导出可编辑 PPTX…") { export(.powerPoint) }
                Button("导出投影 PDF…") { export(.pdf) }
            } label: { Label(importing ? "正在导入" : "交换文件", systemImage: "arrow.left.arrow.right") }
            .fixedSize()
            Button(action: runPreflight) { Label("放映前检查", systemImage: "checklist") }
                .disabled(checkingPreflight)
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
            ScrollViewReader { scroll in
                List(selection: Binding<Set<UUID>>(
                    get: { selectedPages.isEmpty ? [slide.id] : selectedPages },
                    set: { selection in
                        pageCommands = true
                        if self.selectedPages != selection { objectID = nil; editingID = nil }
                        selectedPageIDs = selection
                        let added = deck.slides.last { selection.contains($0.id) && $0.id != slide.id }
                        if selection.count == 1 || !selection.contains(slide.id) {
                            slideID = added?.id ?? selection.first ?? slide.id
                        }
                    }
                )) {
                    ForEach(visibleSlides) { row in
                        slideRow(row).tag(row.id).id(row.id)
                    }
                    .onMove(perform: search.isEmpty && collapsedSections.isEmpty ? reorder : nil)
                }
                .listStyle(.sidebar)
                .onChange(of: slide.id) {
                    if let range = sectionRange(slide.id) {
                        if deck.slides[range.lowerBound].id != slide.id {
                            collapsedSections.remove(deck.slides[range.lowerBound].id)
                        }
                    }
                    scroll.scrollTo(slide.id, anchor: .center)
                }
            }
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

    private var visibleSlides: [Slide] {
        guard search.isEmpty, !collapsedSections.isEmpty else { return filteredSlides }
        var sectionStart: Slide?
        return deck.slides.filter { row in
            if row.section != sectionStart?.section || sectionStart == nil { sectionStart = row }
            return row.id == sectionStart?.id || (sectionStart.map { !collapsedSections.contains($0.id) } ?? true)
        }
    }

    private func slideRow(_ row: Slide) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            let position = deck.slides.firstIndex { $0.id == row.id } ?? 0
            if !row.section.isEmpty && (!search.isEmpty || position == 0 || deck.slides[position - 1].section != row.section) {
                if search.isEmpty {
                    Button {
                        if collapsedSections.contains(row.id) { collapsedSections.remove(row.id) }
                        else { collapsedSections.insert(row.id) }
                        selectedPageIDs = [row.id]
                        slideID = row.id
                        pageCommands = true
                    } label: {
                        Label(row.section, systemImage: collapsedSections.contains(row.id) ? "chevron.right" : "chevron.down")
                            .font(.caption.weight(.semibold)).lineLimit(1)
                    }.buttonStyle(.plain)
                } else {
                    Text(row.section).font(.caption.weight(.semibold)).lineLimit(1).foregroundStyle(.secondary)
                }
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
        .simultaneousGesture(TapGesture().onEnded { pageCommands = true })
        .contextMenu {
            let pages = selectedPages.contains(row.id) ? selectedPages : [row.id]
            if pages.count > 1 {
                Button("复制所选 \(pages.count) 页") { duplicateSlides(pages) }
                Button("所选页整体上移") { moveSlides(pages, by: -1) }
                Button("所选页整体下移") { moveSlides(pages, by: 1) }
                Button("删除所选 \(pages.count) 页", role: .destructive) { pendingDeletion = pages }
                Divider()
            }
            Button("复制此页") { duplicateSlides([row.id]) }
            Button("上移一页") { moveSlide(row.id, delta: -1) }.disabled(row.id == deck.slides.first?.id)
            Button("下移一页") { moveSlide(row.id, delta: 1) }.disabled(row.id == deck.slides.last?.id)
            if !row.section.isEmpty {
                Divider()
                Button("重命名整章…") { renameSection(row.id) }
                Button("上移整章") { moveSection(row.id, delta: -1) }
                    .disabled(adjacentSection(row.id, delta: -1) == nil || !search.isEmpty)
                Button("下移整章") { moveSection(row.id, delta: 1) }
                    .disabled(adjacentSection(row.id, delta: 1) == nil || !search.isEmpty)
            }
            Button("删除此页", role: .destructive) { deleteSlides([row.id]) }
        }
    }

    private var workspace: some View {
        GeometryReader { geometry in
            let scale = max(0.1, min((geometry.size.width - 48) / Deck.size.width,
                                     (geometry.size.height - 48) / Deck.size.height))
            ZStack {
                Color(nsColor: .underPageBackgroundColor)
                    .onTapGesture { focusCanvas(); objectID = nil; editingID = nil }
                ZStack(alignment: .topLeading) {
                    SlideSurface(slide: slide, images: deck.images, omittedObject: editingID)
                        .onTapGesture { focusCanvas(); objectID = nil; editingID = nil }
                    ForEach(slide.objects) { object in
                        objectOverlay(object, scale: scale)
                    }
                    if let selection, editingID == nil {
                        let object = slide.objects[selection]
                        SlideResizeHandles(frame: object.frame, scale: scale, proportional: object.kind == .image) { frame in
                            changeObjectFrame(object.id, to: frame)
                        }
                        .frame(width: Deck.size.width * scale, height: Deck.size.height * scale)
                        .id(object.id)
                        .zIndex(2)
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
            TextEditor(text: textBinding(object.id))
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
                          select: { focusCanvas(); objectID = object.id },
                          edit: {
                              focusCanvas()
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
            Capsule().fill(.secondary.opacity(0.45)).frame(width: 34, height: 4)
                .frame(maxWidth: .infinity)
                .frame(height: 12).contentShape(Rectangle())
                .gesture(DragGesture(coordinateSpace: .global)
                    .updating($notesResize) { drag, value, _ in value = -Double(drag.translation.height) }
                    .onEnded { drag in notesHeight = (notesHeight - Double(drag.translation.height)).clamped(72...260) })
                .accessibilityHidden(true)
            HStack {
                Label("逐字讲稿", systemImage: "note.text").font(.headline)
                Text("第 \(index + 1) 页").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Stepper("\(Int(notesFontSize)) 磅", value: $notesFontSize, in: 12...36)
                Button("专注视图") { notesFocus = true }
            }
            TextEditor(text: slideBinding(\.speakerNotes))
                .font(.system(size: notesFontSize))
                .scrollContentBackground(.hidden)
                .frame(height: (notesHeight + notesResize).clamped(72...260))
                .accessibilityLabel("逐字讲稿")
        }
        .padding(.horizontal, 12).padding(.bottom, 10)
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
                        TextEditor(text: textBinding(object.id))
                            .frame(height: 82)
                            .border(.secondary.opacity(0.22))
                            .accessibilityLabel("文本框内容")
                        number("字号", object: object, key: \.fontSize, range: 8...200)
                        Toggle("粗体", isOn: objectBinding(object.id, \.bold, fallback: false))
                        Menu("文字对齐") {
                            Button("左对齐") { setAlignment(.left, for: object.id) }
                            Button("居中") { setAlignment(.center, for: object.id) }
                            Button("右对齐") { setAlignment(.right, for: object.id) }
                            Button("两端对齐") { setAlignment(.justified, for: object.id) }
                        }
                    }
                    if object.kind == .image {
                        cropControls(object)
                    } else {
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
                            focusCanvas()
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

    private func cropControls(_ object: SlideObject) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Menu("图片裁剪") {
                Button("等比适应图片") { setPictureFit(object, fill: false) }
                Button("等比填充画框") { setPictureFit(object, fill: true) }
                Button("重置裁剪") { objectBinding(object.id, \.pictureCrop, fallback: nil).wrappedValue = nil }
            }
            Grid(alignment: .leading) {
                GridRow { cropField("左", object, \.left, opposite: \.right)
                    cropField("右", object, \.right, opposite: \.left) }
                GridRow { cropField("上", object, \.top, opposite: \.bottom)
                    cropField("下", object, \.bottom, opposite: \.top) }
            }
        }
    }

    private func cropField(_ label: String, _ object: SlideObject, _ edge: WritableKeyPath<PictureCrop, Double>,
                           opposite: KeyPath<PictureCrop, Double>) -> some View {
        HStack(spacing: 3) {
            Text(label).foregroundStyle(.secondary)
            TextField(label, value: Binding(
                get: { (slide.objects.first { $0.id == object.id }?.pictureCrop ?? .init())[keyPath: edge] },
                set: { value in
                    guard let position = slide.objects.firstIndex(where: { $0.id == object.id }) else { return }
                    var area = slide.objects[position].pictureCrop ?? .init()
                    area[keyPath: edge] = value.clamped(0...max(0, 0.99 - area[keyPath: opposite]))
                    document.deck.slides[index].objects[position].pictureCrop = area == .init() ? nil : area
                }), format: .percent.precision(.fractionLength(0...1)))
                .labelsHidden().textFieldStyle(.roundedBorder).frame(minWidth: 45)
        }
    }

    private func setPictureFit(_ object: SlideObject, fill: Bool) {
        guard let id = object.imageID, let data = deck.images[id], let image = SlideDrawing.picture(data),
              let position = slide.objects.firstIndex(where: { $0.id == object.id }) else { return }
        let size = CGSize(width: CGFloat(image.width), height: CGFloat(image.height))
        var updated = object
        if fill {
            let area = PictureCrop.filling(image: size, frame: object.frame.size)
            updated.pictureCrop = area == .init() ? nil : area
        } else {
            let scale = min(object.width / size.width, object.height / size.height)
            let width = max(1, size.width * scale)
            let height = max(1, size.height * scale)
            updated.x = object.frame.midX - width / 2
            updated.y = object.frame.midY - height / 2
            updated.width = width
            updated.height = height
            updated.pictureCrop = nil
        }
        if updated != object { document.deck.slides[index].objects[position] = updated }
    }

    private func changeObjectFrame(_ id: UUID, to frame: CGRect) {
        guard let position = slide.objects.firstIndex(where: { $0.id == id }) else { return }
        var object = slide.objects[position]
        guard object.frame != frame else { return }
        object.x = Double(frame.minX).clamped(-10_000...10_000)
        object.y = Double(frame.minY).clamped(-10_000...10_000)
        object.width = frame.width
        object.height = frame.height
        document.deck.slides[index].objects[position] = object
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

    private func setAlignment(_ alignment: SlideParagraph.Alignment, for id: UUID) {
        guard let position = slide.objects.firstIndex(where: { $0.id == id }) else { return }
        var object = slide.objects[position]
        var layout = object.textLayout ?? .init()
        let count = object.text.components(separatedBy: "\n").count
        layout.paragraphs = (0..<count).map { index in
            var style = layout.paragraphs.indices.contains(index) ? layout.paragraphs[index] : .init()
            style.alignment = alignment
            return style
        }
        object.textLayout = layout
        document.deck.slides[index].objects[position] = object
    }

    private func textBinding(_ id: UUID) -> Binding<String> {
        Binding(
            get: { slide.objects.first { $0.id == id }?.text ?? "" },
            set: { value in
                guard let position = slide.objects.firstIndex(where: { $0.id == id }) else { return }
                var object = slide.objects[position]
                object.replaceText(with: value)
                document.deck.slides[index].objects[position] = object
            }
        )
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
        selectPages([next.id])
    }

    private static let pagePasteboard = NSPasteboard.PasteboardType("com.kongslides.clipboard.slides")
    private static let objectPasteboard = NSPasteboard.PasteboardType("com.kongslides.clipboard.object")

    private func focusCanvas() {
        pageCommands = false
        if let window = NSApp.keyWindow, window.firstResponder is NSTextView {
            window.makeFirstResponder(nil)
        }
    }

    private func handleShortcut(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let pages = selectedPages.isEmpty ? [slide.id] : selectedPages
        if modifiers.isEmpty, [51, 117].contains(event.keyCode) {
            if pageCommands { pendingDeletion = pages; return true }
            if let objectID { removeObject(objectID); return true }
        }
        guard modifiers == .command else { return false }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "c":
            return copySelection(pages)
        case "v":
            return pasteSelection()
        case "d":
            if pageCommands { duplicateSlides(pages); return true }
            guard let selection else { return false }
            let box = SlideClipboard(slides: [Slide(objects: [slide.objects[selection]])], images: deck.images)
            insert(box, at: index, asObject: true)
            return true
        case "a":
            guard pageCommands else { return false }
            selectedPageIDs = Set(visibleSlides.map(\.id))
            return true
        default:
            return false
        }
    }

    private func copySelection(_ pages: Set<UUID>) -> Bool {
        let payload: SlideClipboard
        let type: NSPasteboard.PasteboardType
        if pageCommands {
            payload = SlideClipboard(slides: deck.slides.filter { pages.contains($0.id) }, images: deck.images)
            type = Self.pagePasteboard
        } else {
            guard let selection else { return false }
            payload = SlideClipboard(slides: [Slide(objects: [slide.objects[selection]])], images: deck.images)
            type = Self.objectPasteboard
        }
        guard let data = try? JSONEncoder().encode(payload) else { return false }
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setData(data, forType: type)
    }

    private func pasteSelection() -> Bool {
        let clipboard = NSPasteboard.general
        let type = pageCommands ? Self.pagePasteboard : Self.objectPasteboard
        guard let data = clipboard.data(forType: type), data.count <= 192 * 1024 * 1024 else { return false }
        do {
            let contents = try JSONDecoder().decode(SlideClipboard.self, from: data).validated()
            let last = deck.slides.lastIndex { selectedPages.contains($0.id) } ?? index
            insert(contents, at: pageCommands ? last + 1 : index, asObject: !pageCommands)
        } catch { linkedError = "剪贴板中的 KongSlides 内容无法读取。" }
        return true
    }

    private func insert(_ clipboard: SlideClipboard, at position: Int, asObject: Bool) {
        var updated = deck
        let copies = clipboard.copies(into: &updated)
        if asObject {
            guard copies.count == 1, var object = copies.first?.objects.first, copies.first?.objects.count == 1 else { return }
            object.x = (object.x + 12).clamped(-10_000...10_000)
            object.y = (object.y + 12).clamped(-10_000...10_000)
            updated.slides[index].objects.append(object)
            document.deck = updated
            objectID = object.id
        } else {
            updated.slides.insert(contentsOf: copies, at: position)
            document.deck = updated
            search = ""
            selectPages(copies.map(\.id))
        }
    }

    private func selectPages(_ ids: [UUID]) {
        guard let first = ids.first else { return }
        selectedPageIDs = Set(ids)
        slideID = first
        objectID = nil
        editingID = nil
        pageCommands = true
    }

    private func duplicateSlides(_ ids: Set<UUID>) {
        let pages = deck.slides.filter { ids.contains($0.id) }
        guard let last = deck.slides.lastIndex(where: { ids.contains($0.id) }) else { return }
        insert(SlideClipboard(slides: pages, images: deck.images), at: last + 1, asObject: false)
    }

    private func deleteSlides(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        var updated = deck
        let current = slide.id
        updated.slides.removeAll { ids.contains($0.id) }
        if updated.slides.isEmpty { updated.slides = [Slide()] }
        let next = updated.slides.first { $0.id == current } ?? updated.slides[min(index, updated.slides.count - 1)]
        document.deck = (try? updated.validated()) ?? updated
        selectPages([next.id])
    }

    private func moveSlides(_ ids: Set<UUID>, by delta: Int) {
        var updated = deck
        updated.moveSelectedSlides(ids, by: delta)
        if updated.slides != deck.slides { document.deck = updated }
    }

    private func renameSection(_ id: UUID) {
        guard let range = sectionRange(id) else { return }
        let alert = NSAlert()
        alert.messageText = "重命名章节"
        let input = NSTextField(string: deck.slides[range.lowerBound].section)
        input.frame = CGRect(x: 0, y: 0, width: 265, height: 25)
        alert.accessoryView = input
        alert.window.initialFirstResponder = input
        alert.addButton(withTitle: "重命名")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        var updated = deck
        for position in range { updated.slides[position].section = name }
        document.deck = updated
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
        pageCommands = false
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
            pageCommands = false
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
                    try PowerPoint.read(url, fontAvailable: { NSFont(name: $0, size: 12) != nil }) { data in
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
                selectPages(Array(imported.deck.slides.prefix(1).map(\.id)))

                reviewMode = .imported
            } catch {
                linkedError = "无法导入这份 PPTX。\n\(error.localizedDescription)"
            }
        }
    }

    private func reviewPanel(_ mode: SlideReviewMode) -> some View {
        SlideReviewPanel(
            mode: mode,
            rows: mode == .imported ? SlideReviewRow.imported(deck) : currentPreflightRows,
            pageCount: mode == .imported ? deck.slides.filter { $0.importReport != nil }.count : preflightPageCount,
            checking: mode == .preflight && checkingPreflight,
            refresh: runPreflight,
            close: { reviewMode = nil },
            reveal: { row in
                guard let target = deck.slides.first(where: { $0.id == row.slideID }) else { return }
                search = ""
                editingID = nil
                selectPages([target.id])
                objectID = target.objects.first { $0.id == row.objectID }?.id
                pageCommands = objectID == nil
            }
        )
    }

    private var currentPreflightRows: [SlideReviewRow] {
        let pageNumber = Dictionary(uniqueKeysWithValues: deck.slides.enumerated().map { ($0.element.id, $0.offset + 1) })
        return preflightRows.compactMap { row in
            guard let page = pageNumber[row.slideID] else { return nil }
            var current = row
            current.page = page
            return current
        }
    }

    private func runPreflight() {
        reviewMode = .preflight
        guard !checkingPreflight else { return }
        let snapshot = deck
        checkingPreflight = true
        preflightRows = []
        Task { @MainActor in
            let result = await Task.detached(priority: .userInitiated) { SlideReviewRow.preflight(snapshot) }.value
            preflightRows = result
            preflightPageCount = snapshot.slides.count
            checkingPreflight = false
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
